require File.expand_path('../constants', __FILE__)
require File.expand_path('../errors', __FILE__)
require 'set'

module Visitable
  def accept(visitor)
    visitor.visit(self)
  end

  attr_accessor :parent_node, :scope, :force_newline
  alias parent parent_node
  alias parent= parent_node=

  attr_writer :compiled_output
  def compiled_output
    @compiled_output ||= ''
  end

  # catches "descendant_of_#{some_class}?" methods
  # def descendant_of_call_node?
  #   CallNode === self.parent_node
  # end
  DESCENDANT_OF_REGEX = /\Adescendant_of_(.*?)\?/
  def method_missing(method, *args, &blk)
    if method =~ DESCENDANT_OF_REGEX
      parent_node_name = $1.split('_').map(&:capitalize).join
      parent_node = self.class.const_get parent_node_name
      parent_node === self.parent_node
    else
      super
    end
  end
  def respond_to?(method, include_private = false)
    super || method =~ DESCENDANT_OF_REGEX
  end
end

module Walkable
  include Enumerable

  def each(&block)
    children.each(&block)
  end
  alias walk each

  def previous
    idx = index
    return unless idx
    parent.children.fetch(idx - 1)
  end

  def child_previous_to(node)
    idx = children.find_index(node)
    return unless idx
    children.fetch(idx - 1)
  end

  def insert_before(node, new_node)
    idx = children.find_index(node)
    return unless idx
    children.insert(idx-1, new_node)
  end

  def next
    idx = index
    return unless idx
    parent.children.fetch(idx + 1)
  end

  def child_after(node)
    idx = children.find_index(node)
    return unless idx
    children.fetch(idx + 1)
  end

  def insert_after(node, new_node)
    idx = children.find_index(node)
    return unless idx
    children.insert(idx+1, new_node)
  end

  def index
    parent.children.find_index(self)
  end

  def remove
    idx = index
    parent.children.slice!(idx) if idx
  end

  def replace_with(new_node)
    idx = index
    return unless idx
    parent.children.insert(idx, new_node)
    parent.children.slice!(idx+1)
    new_node
  end
end

module Indentable
  def indent
    @indent ||= " " * 2
  end
end

# Collection of nodes each one representing an expression.
class Nodes < Struct.new(:nodes)
  include Visitable
  include Walkable

  def <<(node)
    nodes << node
    self
  end

  def concat(list_of_nodes)
    nodes.concat(list_of_nodes)
    self
  end

  # forward missing methods to `nodes` array
  def method_missing(method, *args, &block)
    if nodes.respond_to?(method)
      nodes.send(method, *args, &block)
    else
      super
    end
  end

  def respond_to?(method, include_private = false)
    super || nodes.respond_to?(method, include_private)
  end

  def children
    nodes
  end
end

class SublistNode < Nodes; end

# Literals are static values that have a Ruby representation, eg.: a string, number, list,
# true, false, nil, etc.
class LiteralNode < Struct.new(:value)
  include Visitable
end

class KeywordNode < Struct.new(:value)
  include Visitable
end

class NumberNode < LiteralNode; end

class StringNode < Struct.new(:value, :type) # type: :d or :s for double- or single-quoted
  include Visitable
end

class RegexpNode < LiteralNode; end

class ListNode < LiteralNode
  include Walkable
  def self.wrap(value)
    val = Array === value ? value : [value]
    new(val)
  end

  def children
    value
  end
end

class ListUnpackNode < ListNode
  def rest
    value.last
  end
end

class DictionaryNode < LiteralNode; end
class ScopeModifierLiteralNode < LiteralNode; end

class TrueNode < LiteralNode
  def initialize() super(true) end
end

class FalseNode < LiteralNode
  def initialize() super(false) end
end

class NilNode < LiteralNode
  def initialize() super(nil) end
end

class NewlineNode < LiteralNode
  def initialize() super("\n") end
end

class ExLiteralNode < LiteralNode
  def initialize(*)
    super
    self.force_newline = true
  end
end

class FinishNode < KeywordNode
  def initialize() super("finish\n") end
end

class BreakNode < KeywordNode
  def initialize() super("break\n") end
end

class ContinueNode < KeywordNode
  def initialize() super("continue\n") end
end

class ReturnNode < Struct.new(:expression)
  include Visitable
  include Walkable

  def children
    [expression]
  end
end

class WrapInParensNode < Struct.new(:expression)
  include Visitable
  include Walkable

  def children
    [expression]
  end
end

module FullyNameable
  def self.included(base)
    base.class_eval do
      raise "#{base} must define method 'name'" unless method_defined?(:name)
    end
  end

  def full_name
    if respond_to?(:scope_modifier)
      "#{scope_modifier}#{name}"
    elsif respond_to?(:prefix)
      "#{prefix}#{name}"
    end
  end
end

# Node of a method call, can take any of these forms:
#
#   Method()
#   s:Method(argument1, argument2)
class CallNode < Struct.new(:scope_modifier, :name, :arguments)
  include Riml::Constants
  include Visitable
  include FullyNameable
  include Walkable

  ALL_BUILTIN_FUNCTIONS = BUILTIN_FUNCTIONS + BUILTIN_COMMANDS
  ALL_BUILTIN_COMMANDS  = BUILTIN_COMMANDS  + RIML_COMMANDS + VIML_COMMANDS

  def initialize(scope_modifier, name, arguments)
    super
    remove_parens_wrapper if builtin_command?
  end

  # TODO: find way to remove this hack
  def remove_parens_wrapper
    return unless WrapInParensNode === arguments.first
    arguments[0] = arguments[0].expression
  end

  def builtin_function?
    return false unless name.is_a?(String)
    scope_modifier.nil? and ALL_BUILTIN_FUNCTIONS.include?(name)
  end

  def builtin_command?
    return false unless name.is_a?(String)
    scope_modifier.nil? and ALL_BUILTIN_COMMANDS.include?(name)
  end

  def must_be_explicit_call?
    return false if builtin_command?
    return true  if parent.instance_of?(Nodes)
    false
  end

  def autoload?
    name.include?('#')
  end

  def children
    if name.is_a?(String)
      arguments
    else
      [name] + arguments
    end
  end
end

# Node of an explicitly called method, can take any of these forms:
#
#   call Method()
#   call s:Method(argument1, argument2)
class ExplicitCallNode < CallNode; end
class RimlCommandNode  < CallNode

  def initialize(*)
    super
    if arguments.empty? || !arguments.all? { |arg| arg.is_a?(StringNode) }
      raise Riml::UserArgumentError, "#{name.inspect} error: must pass string (name of file)"
    end
  end

  def each_existing_file!
    files = []
    arguments.map(&:value).each do |file|
      if File.exists?(File.join(Riml.source_path, file))
        files << file
      else
        raise Riml::FileNotFound, "#{file.inspect} could not be found in " \
          "source path (#{Riml.source_path.inspect})"
      end
    end
    return unless block_given?
    # all files exist
    files.each do |f|
      begin
        yield f
      rescue Riml::IncludeFileLoop
        arguments.delete_if { |arg| arg.value == f }
      end
    end
  end
end

class OperatorNode < Struct.new(:operator, :operands)
  include Visitable
  include Walkable

  def children
    operands
  end
end

class BinaryOperatorNode < OperatorNode
  include Riml::Constants

  def operand1() operands[0] end
  def operand1=(val) operands[0] = val end

  def operand2() operands[1] end
  def operand2=(val) operands[1] = val end

  def ignorecase_capable_operator?(operator)
    IGNORECASE_CAPABLE_OPERATORS.include?(operator)
  end
end

class UnaryOperatorNode < OperatorNode
  alias operand operands
end

# operator = :ternary
# operands = [condition, if_expr, else_expr]
class TernaryOperatorNode < OperatorNode
  def initialize(operands, operator=:ternary)
    super(operator, operands)
  end

  def condition() operands[0] end

  def if_expr() operands[1] end

  def else_expr() operands[2] end
end

# let var = 2
# let s:var = 4
class AssignNode < Struct.new(:operator, :lhs, :rhs)
  include Visitable
  include Walkable

  def children
    [lhs, rhs]
  end
end

module QuestionVariableExistence
  def self.included(base)
    base.class_eval do
      raise "#{base} must define method 'name'" unless method_defined?(:name)
      alias name_with_question_mark name
      def name_without_question_mark
        if question_existence?
          name_with_question_mark[0...-1]
        else
          name_with_question_mark
        end
      end
      alias name name_without_question_mark
    end
  end

  def question_existence?
    name_with_question_mark[-1] == ??
  end
end

# s:var
# var
class GetVariableNode < Struct.new(:scope_modifier, :name)
  include Visitable
  include FullyNameable
  include QuestionVariableExistence
end

# &autoindent
# @q
class GetSpecialVariableNode < Struct.new(:prefix, :name)
  include Visitable
  include FullyNameable
end

class GetCurlyBraceNameNode < Struct.new(:scope_modifier, :variable)
  include Visitable
  include Walkable

  def children
    [variable]
  end
end

class CurlyBraceVariable < Struct.new(:parts)
  include Visitable
  include Walkable

  def <<(part)
    parts << part
    self
  end

  def children
    parts
  end
end

class CurlyBracePart < Struct.new(:value)
  include Visitable
  include Walkable

  def interpolated?
    GetVariableNode === value || GetSpecialVariableNode === value || nested?
  end

  def nested?
    value.is_a?(Array) && value.detect {|part| part.is_a?(CurlyBracePart)}
  end

  def children
    return [] unless interpolated?
    return value if nested?
    [value]
  end
end

class UnletVariableNode < Struct.new(:bang, :variables)
  include Visitable
  include Walkable

  def <<(variable)
    variables << variable
    self
  end

  def children
    variables
  end
end

# Method definition.
class DefNode < Struct.new(:bang, :scope_modifier, :name, :parameters, :keyword, :expressions)
  include Visitable
  include Indentable
  include FullyNameable
  include Walkable

  attr_accessor :original_name

  def initialize(*args)
    super
    # max number of arguments in viml
    if parameters.size > 20
      raise Riml::UserArgumentError, "can't have more than 20 parameters for #{full_name}"
    end
  end

  SPLAT = lambda {|arg| arg == '...' || arg[0] == "*"}

  # ["arg1", "arg2"}
  def argument_variable_names
    @argument_variable_names ||= parameters.reject(&SPLAT)
  end

  # returns the splat argument or nil
  def splat
    @splat ||= parameters.detect(&SPLAT)
  end

  def keyword
    if name.include?('.')
      'dict'
    else
      super
    end
  end

  def autoload?
    name.include?('#')
  end

  def super_node
    expressions.detect {|n| SuperNode === n}
  end

  def to_scope
    ScopeNode.new.tap do |scope|
      scope.argument_variable_names += argument_variable_names
      scope.function = self
    end
  end

  def children
     [expressions]
  end

  def method_missing(method, *args, &blk)
    if children.respond_to?(method)
      children.send(method, *args, &blk)
    else
      super
    end
  end
end

class ScopeNode
  attr_writer :for_node_variable_names, :argument_variable_names
  attr_accessor :function

  def for_node_variable_names
    @for_node_variable_names ||= Set.new
  end

  def argument_variable_names
    @argument_variable_names ||= Set.new
  end

  alias function? function

  def initialize_copy(source)
    super
    self.for_node_variable_names = for_node_variable_names.dup
    self.argument_variable_names = argument_variable_names.dup
    self.function = source.function
  end

  def merge(other)
    dup.merge! other
  end

  def merge!(other)
    unless other.is_a?(ScopeNode)
      raise ArgumentError, "other must be ScopeNode, is #{other.class}"
    end
    self.for_node_variable_names += other.for_node_variable_names
    self.argument_variable_names -= for_node_variable_names
    self.function = other.function if function.nil? && other.function
    self
  end
end

class DefMethodNode < DefNode
  def to_def_node
    def_node = DefNode.new(bang, 'g:', name, parameters, 'dict', expressions)
    def_node.parent = parent
    def_node
  end
end

# abstract control structure
class ControlStructure < Struct.new(:condition, :body)
  include Visitable
  include Indentable
  include Walkable

  def children
    [condition, body]
  end

  def wrap_condition_in_parens!
    return if WrapInParensNode === condition
    _parent = condition.parent
    self.condition = WrapInParensNode.new(condition)
    self.condition.parent = _parent
  end
end

class IfNode < ControlStructure; end
class WhileNode < ControlStructure; end

class UnlessNode < ControlStructure
  def initialize(*)
    super
    wrap_condition_in_parens!
  end
end
class UntilNode < ControlStructure
  def initialize(*)
    super
    wrap_condition_in_parens!
  end
end

class ElseNode < Struct.new(:expressions)
  include Visitable
  include Walkable
  alias body expressions

  def <<(expr)
    expressions << expr
    self
  end

  def pop
    expressions.pop
  end

  def last
    expressions.last
  end

  def children
    [expressions]
  end
end

class ElseifNode < ControlStructure
  include Visitable
  include Walkable
  alias expressions body

  def <<(expr)
    expressions << expr
    self
  end

  def pop
    expressions.pop
  end

  def last
    expressions.last
  end

  def children
    [expressions]
  end
end

# for variable in someFunction(1,2,3)
#   echo variable
# end
#
# OR
#
# for variable in [1,2,3]
#   echo variable
# end
class ForNode < Struct.new(:variable, :in_expression, :expressions)
  include Visitable
  include Indentable
  include Walkable

  alias for_variable variable

  def variables
    variable if ListNode === variable
  end

  def for_node_variable_names
    if ListNode === variable
      variable.value.map(&:name)
    else
      [variable]
    end
  end

  def to_scope
    ScopeNode.new.tap {|s| s.for_node_variable_names += for_node_variable_names}
  end

  def children
    [variable, in_expression, expressions]
  end
end

class DictGetNode < Struct.new(:dict, :keys)
  include Visitable
  include Walkable

  def children
    [dict] + keys
  end
end

# dict['key']
# dict['key1']['key2']
class DictGetBracketNode < DictGetNode; end

# dict.key
# dict.key.key2
class DictGetDotNode < DictGetNode; end


# list_or_dict[0]
# function()[identifier]
class ListOrDictGetNode < Struct.new(:list_or_dict, :keys)
  include Visitable
  include Walkable

  alias list list_or_dict
  alias dict list_or_dict
  def children
    [list_or_dict] + keys
  end
end

class TryNode < Struct.new(:try_block, :catch_nodes, :finally_block)
  include Visitable
  include Indentable
  include Walkable

  def children
    [try_block, catch_nodes, finally_block]
  end
end

class CatchNode < Struct.new(:regexp, :expressions)
  include Visitable
  include Walkable

  def children
    [expressions]
  end
end

class ClassDefinitionNode < Struct.new(:name, :superclass_name, :expressions)
  include Visitable
  include Walkable

  def superclass?
    not superclass_name.nil?
  end

  def constructor
    expressions.detect do |n|
      DefNode === n && (n.name == 'initialize' || n.name.match(/Constructor\Z/))
    end
  end
  alias constructor? constructor

  def constructor_name
    "#{name}Constructor"
  end

  def constructor_obj_name
    name[0].downcase + name[1..-1] + "Obj"
  end

  def children
    [expressions]
  end
end

class SuperNode < Struct.new(:arguments, :with_parens)
  include Visitable
  include Walkable

  def use_all_arguments?
    arguments.empty? && !with_parens
  end

  def children
    arguments
  end
end

class ObjectInstantiationNode < Struct.new(:call_node)
  include Visitable
  include Walkable

  def children
    [call_node]
  end
end
