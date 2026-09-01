Fixnum = Integer unless defined?(Fixnum)
Bignum = Integer unless defined?(Bignum)
File.singleton_class.alias_method :exists?, :exist? unless File.respond_to?(:exists?)
Dir.singleton_class.alias_method :exists?, :exist? unless Dir.respond_to?(:exists?)
class Object
  def =~(other); nil; end unless method_defined?(:=~)
  def !~(other); !(self =~ other); end unless method_defined?(:!~)
end
require 'uri'
module URI
  def self.encode(*args); DEFAULT_PARSER.escape(*args); end unless respond_to?(:encode)
  def self.escape(*args); DEFAULT_PARSER.escape(*args); end unless respond_to?(:escape)
  def self.decode(*args); DEFAULT_PARSER.unescape(*args); end unless respond_to?(:decode)
  def self.unescape(*args); DEFAULT_PARSER.unescape(*args); end unless respond_to?(:unescape)
end

module Xiki
  class Environment

    # Will return either :osx, :linux, :windows, or :unknown.
    # Environment.os
    def self.os

      return "osx" if RUBY_PLATFORM =~ /darwin/i
      return "linux" if RUBY_PLATFORM =~ /linux/i
      return "solaris" if RUBY_PLATFORM =~ /solaris/i
      return "windows" if RUBY_PLATFORM =~ /mswin/i

      :unknown
    end

    def self.xsh= val
      $el.elvar.environment_xsh = val
    end
    def self.xsh?
      return nil if ! $el.boundp(:environment_xsh)
      $el.elvar.environment_xsh
    end

    def self.current_emacs_path
      # This is only currently implemented for the mac.
      # Someone, make this work for Linux also.

      result = `ps -ef`[/ (\/.+\/(Aquamacs|Aquamacs Emacs|Emacs)\.app)/, 1]
    end

    def self.emacs
      $el
    end

    def self.gui_emacs
      @@gui_emacs ||= ($el && $el.display_graphic_p)
    end

  end
end
