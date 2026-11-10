require "log"

module CrystKit::Platform::Linux
  {% if `pkg-config --exists webkit2gtk-4.1 2>/dev/null && echo yes`.strip == "yes" %}
    @[Link("webkit2gtk-4.1")]
  {% else %}
    @[Link("webkit2gtk-4.0")]
  {% end %}
  lib LibWebKitPrint
    fun webkit_print_operation_new(web_view : Void*) : Void*
    fun webkit_print_operation_run_dialog(operation : Void*, parent : Void*) : Void*
    fun webkit_print_operation_print(operation : Void*) : Nil
    fun webkit_print_operation_set_print_settings(operation : Void*, settings : Void*) : Nil
  end

  @[Link("gtk-3")]
  lib LibGtkPrint
    fun gtk_print_settings_new : Void*
    fun gtk_print_settings_set_n_copies(settings : Void*, n_copies : Int32) : Nil
    fun gtk_print_settings_set_orientation(settings : Void*, orientation : Int32) : Nil
    fun gtk_print_settings_set_paper_size(settings : Void*, paper_size : Void*) : Nil
    fun gtk_paper_size_new(name : UInt8*) : Void*
    fun gtk_paper_size_free(size : Void*) : Nil
    fun gtk_print_settings_set(settings : Void*, key : UInt8*, value : UInt8*) : Nil
  end

  module Printing
    Log = ::Log.for(self)

    ORIENTATION_PORTRAIT  = 0
    ORIENTATION_LANDSCAPE = 1

    def self.print(wv : Void*, options) : Bool
      operation = LibWebKitPrint.webkit_print_operation_new(wv)
      return false if operation.null?

      settings = LibGtkPrint.gtk_print_settings_new
      apply_settings(settings, options)
      LibWebKitPrint.webkit_print_operation_set_print_settings(operation, settings)
      LibWebKitPrint.webkit_print_operation_print(operation)
      true
    rescue ex
      Log.error { "Linux print failed: #{ex.message}" }
      false
    end

    def self.print_to_pdf(wv : Void*, output : String, options) : Bool
      operation = LibWebKitPrint.webkit_print_operation_new(wv)
      return false if operation.null?

      settings = LibGtkPrint.gtk_print_settings_new
      apply_settings(settings, options)

      uri = "file://#{output}"
      LibGtkPrint.gtk_print_settings_set(settings, "output-uri", uri)

      LibWebKitPrint.webkit_print_operation_set_print_settings(operation, settings)
      LibWebKitPrint.webkit_print_operation_print(operation)
      true
    rescue ex
      Log.error { "Linux print to PDF failed: #{ex.message}" }
      false
    end

    def self.list_printers : Array(String)
      # Linux printing uses CUPS; query via D-Bus or lpstat
      # Return a basic list for now
      ["Default Printer"]
    rescue
      [] of String
    end

    def self.show_dialog(wv : Void*, options) : Bool
      operation = LibWebKitPrint.webkit_print_operation_new(wv)
      return false if operation.null?

      settings = LibGtkPrint.gtk_print_settings_new
      apply_settings(settings, options)
      LibWebKitPrint.webkit_print_operation_set_print_settings(operation, settings)
      LibWebKitPrint.webkit_print_operation_run_dialog(operation, Pointer(Void).null)
      true
    rescue ex
      Log.error { "Linux print dialog failed: #{ex.message}" }
      false
    end

    private def self.apply_settings(settings : Void*, options) : Nil
      LibGtkPrint.gtk_print_settings_set_n_copies(settings, options.copies)
      orientation = options.landscape? ? ORIENTATION_LANDSCAPE : ORIENTATION_PORTRAIT
      LibGtkPrint.gtk_print_settings_set_orientation(settings, orientation)

      paper_size = LibGtkPrint.gtk_paper_size_new(options.paper_size.to_unsafe)
      unless paper_size.null?
        LibGtkPrint.gtk_print_settings_set_paper_size(settings, paper_size)
        LibGtkPrint.gtk_paper_size_free(paper_size)
      end
    end
  end
end
