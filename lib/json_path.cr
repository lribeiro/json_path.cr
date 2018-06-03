require "json_path/version"

class String
  @@is_int_regex = /\A[-+]?\d+\z/

  def is_i?
    @@is_int_regex.match(self)
  end

  def as_i(default)
    self.is_i? ? self.to_i : default
  end
end

class JsonPath
  property result
  property expression : String

  def initialize(expr : String)
    @result = Array(JSON::Type).new
    @expression = normalize(expr).sub(/^\$;/, "")
  end

  def normalize(expr : String)
    subx = Array(String).new

    ex = expr.gsub(/[\['](\??\(.*?\))[\]']/) { |x| subx << $1; "[##{subx.size - 1}]" }
    ex = ex.gsub(/'?\.'?|\['?/, ";")
    ex = ex.gsub(/;;;|;;/, ";..;")
    ex = ex.gsub(/;$|'?\]|'$/, "")
    ex = ex.gsub(/#([0-9]+)/) { |x| subx[$1.to_i] }

    ex
  end

  def store(p, v : JSON::Type)
    if p
      @result << v
    end
    return !!p
  end

  def get_node(context, key)
    return context unless key

    case context
    when Array
      context[key.to_i]
    when Hash
      context[key.to_s]
    else
      context
    end
  end

  def trace(expr : String, val : JSON::Type , path : String)
    if expr && expr.size > 0
      x = expr.split(";")
      loc = x.shift
      x = x.join(";")

      case
      when val.is_a?(Hash) && val[loc]?
        trace(x, val[loc], path + ";" + loc)
      when val.is_a?(Array) && loc && loc.is_i? && val.size > loc.to_i
        trace(x, val[loc.to_i], path + ";" + loc)
      when loc == "*"
        walk(loc, x, val, path) do |m, l, x, v, p|
          trace("#{m};#{x}", v, p)
        end
      when (loc == "..")
        trace(x, val, path)
        walk(loc, x, val, path) do |m, l, x, v, p|
          object = get_node(v,m)
          trace("..;" + x.to_s, object, p.to_s + ";" + m.to_s)
        end
      when /,/.match(loc) # [name1,name2,...]
        s = loc.split(/'?,'?/)
        i = 0
        n = s.size

        while i < n
          trace(s[i].to_s + ";" + x.to_s, val, path)
          i += 1
        end
      when (/^\(.*?\)$/.match(loc)) # [(expr)]
        last_idx = path.rindex(";")
        raise "Canf find ; in #{loc}" unless last_idx

        p = path[(last_idx + 1)..-1]
        trace(jp_eval(loc, val).to_s + ";" + x, val, path)
      when (/^\?\(.*?\)$/.match(loc)) # [?(expr)]
        walk(loc, x, val, path) do |m, l, x, v, p|
          question_expr = l.sub(/^\?\((.*?)\)$/, "\\1")
          if jp_eval(question_expr, get_node(v,m))
            trace("#{m};#{x}", v, p)
          end
        end
      when (/^(-?[0-9]*):(-?[0-9]*):?([0-9]*)$/.match(loc)) # [start:end:step]  python slice syntax
        slice(loc, x, val, path)
      end
    else
      store(path, val)
    end
  end

  def walk(loc, expr, val, path)
    case val
    when Array
      val.each_with_index do |object, i|
        yield i, loc, expr, val, path
      end
    when Hash
      val.each do |key, value|
        yield key, loc, expr, val, path
      end
    end
  end

  def slice(loc, expr, val, path)
    if val.is_a?(Array)
      len = val.size
      start = 0
      size = len
      step = 1

      loc.gsub(/^(-?[0-9]*):(-?[0-9]*):?(-?[0-9]*)$/) do |match|
        start = $1.to_i if $1.size > 0
        size = $2.to_i if $2.size > 0
        step = $3.to_i if $3.size > 0
      end

      start = (start < 0) ? [0, start + len].max : [len, start].min
      size = (size < 0) ? [0, size + len].max : [len, size].min

      i = start
      while i < size
        trace(i.to_s + ";" + expr.to_s, val, path)
        i += step
      end
    end
  end

  def eval_exp(field : String, operator : String, operand : String)
    if field
      case operator
      when "=="
        value == operand
      when "!="
        value != operand
      when ">"
        value > operand
      when "<"
        value < operand
      when "<="
        value <= operand
      when ">="
        value >= operand
      when "=~"
        value =~ operand
      else
        raise "JsonPath#eval_exp(String) unexpected operator #{operator}"
      end
    end
  end

  def eval_exp(value : Number, operator : String, operand : Number)
    if value
      case operator
      when "=="
        value == operand
      when "!="
        value != operand
      when ">"
        value > operand
      when "<"
        value < operand
      when "<="
        value <= operand
      when ">="
        value >= operand
      when "+"
        value + operand
      when "-"
        value - operand
      else
        raise "JsonPath#eval_exp(Number) unexpected operator #{operator}"
      end
    end
  end

  def jp_eval(expr : String, _v)
    if _v && _v.responds_to?(:size) &&  _v.size > 0
      case _v
      when Hash
        match = expr.match(/@.(\w+)\s*([<=>!~]*)\s*(\d*)/)

        return unless match

        case
        when $3.nil? || $3.size == 0
          _v[$1]?
        else
          value = $1 == "length" ? _v.size : _v[$1].as(Number).to_i
          eval_exp(value, $2, $3.to_i)
        end
      when Array
        expr.match(/@.(\w+)\s*([\<\=\>\!\~\-\+]+)\s*(\d*)/)
        case
        when ($3.nil? || $3.size == 0) && !$1.nil? && $1.is_i?
          _v[$1.to_i]
        else
          value = case $1
                  when "length"
                    _v.size
                  when /\A[-+]?\d+\z/
                    $1.to_i
                  else
                    raise "js_eval: unsupported operator #{$1}"
                  end
          eval_exp(value, $2, $3.to_i)
        end
      else
        raise "jp_eval: unsupported type #{_v.class} only Array & Hash are acceptable"
      end
    end
  end

  def on(object)
    if @expression && object
      trace(@expression, object.raw, "$")
      return @result || false
    end
  end
end
