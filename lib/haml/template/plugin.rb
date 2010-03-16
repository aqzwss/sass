# This file makes Haml work with Rails
# using the > 2.0.1 template handler API.

module Haml
  class Plugin < Haml::Util.av_template_class(:Handler)
    if (defined?(ActionView::TemplateHandlers) &&
        defined?(ActionView::TemplateHandlers::Compilable)) ||
       (defined?(ActionView::Template) &&
        defined?(ActionView::Template::Handlers) &&
        defined?(ActionView::Template::Handlers::Compilable))
      include Haml::Util.av_template_class(:Handlers)::Compilable
    end

    def compile(template)
      options = Haml::Template.options.dup

      # template is a template object in Rails >=2.1.0,
      # a source string previously
      if template.respond_to? :source
        # Template has a generic identifier in Rails >=3.0.0
        options[:filename] = template.respond_to?(:identifier) ? template.identifier : template.filename
        source = template.source
      else
        source = template
      end

      Haml::Engine.new(source, options).send(:precompiled_with_ambles, [])
    end

    def cache_fragment(block, name = {}, options = nil)
      @view.fragment_for(block, name, options) do
        eval("_hamlout.buffer", block.binding)
      end
    end
  end

  # Rails 3.0 prints a deprecation warning when block helpers
  # return strings that go unused.
  # We want to print the same deprecation warning,
  # so we have to compile in a method call to check for it.
  #
  # I don't like having this in the precompiler pipeline,
  # and I'd like to get rid of it once Rails 3.1 is well-established.
  if defined?(ActionView::OutputBuffer) &&
      Haml::Util.has?(:instance_method, ActionView::OutputBuffer, :append_if_string=)
    module Precompiler
      def push_silent_with_haml_block_deprecation(text, *args)
        unless block_opened? && text =~ ActionView::Template::Handlers::Erubis::BLOCK_EXPR
          return push_silent_without_haml_block_deprecation(text, *args)
        end

        push_silent_without_haml_block_deprecation("_hamlout.append_if_string= #{text}", *args)
      end
      alias_method :push_silent_without_haml_block_deprecation, :push_silent
      alias_method :push_silent, :push_silent_with_haml_block_deprecation
    end

    class Buffer
      def append_if_string=(value)
        if value.is_a?(String) && !value.is_a?(ActionView::NonConcattingString)
          ActiveSupport::Deprecation.warn("- style block helpers are deprecated. Please use =", caller)
          buffer << value
        end
      end
    end
  end
end

if defined? ActionView::Template and ActionView::Template.respond_to? :register_template_handler
  ActionView::Template
else
  ActionView::Base
end.register_template_handler(:haml, Haml::Plugin)

# In Rails 2.0.2, ActionView::TemplateError took arguments
# that we can't fill in from the Haml::Plugin context.
# Thus, we've got to monkeypatch ActionView::Base to catch the error.
if defined?(ActionView::TemplateError) &&
    ActionView::TemplateError.instance_method(:initialize).arity == 5
  class ActionView::Base
    def compile_template(handler, template, file_name, local_assigns)
      render_symbol = assign_method_name(handler, template, file_name)

      # Move begin up two lines so it captures compilation exceptions.
      begin
        render_source = create_template_source(handler, template, render_symbol, local_assigns.keys)
        line_offset = @@template_args[render_symbol].size + handler.line_offset
      
        file_name = 'compiled-template' if file_name.blank?
        CompiledTemplates.module_eval(render_source, file_name, -line_offset)
      rescue Exception => e # errors from template code
        if logger
          logger.debug "ERROR: compiling #{render_symbol} RAISED #{e}"
          logger.debug "Function body: #{render_source}"
          logger.debug "Backtrace: #{e.backtrace.join("\n")}"
        end

        # There's no way to tell Haml about the filename,
        # so we've got to insert it ourselves.
        e.backtrace[0].gsub!('(haml)', file_name) if e.is_a?(Haml::Error)
        
        raise ActionView::TemplateError.new(extract_base_path_from(file_name) || view_paths.first, file_name || template, @assigns, template, e)
      end
      
      @@compile_time[render_symbol] = Time.now
      # logger.debug "Compiled template #{file_name || template}\n ==> #{render_symbol}" if logger
    end
  end
end
