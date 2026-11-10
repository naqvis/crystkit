# GLib and GObject bindings shared by CrystKit's Linux WebView integrations.

@[Link("gobject-2.0")]
lib LibGObject
  fun g_signal_connect_data(instance : Void*, detailed_signal : UInt8*, c_handler : Void*, data : Void*, destroy_data : Void*, connect_flags : Int32) : UInt64
  fun g_signal_handler_disconnect(instance : Void*, handler_id : UInt64) : Nil
  fun g_type_check_instance_is_a(instance : Void*, iface_type : UInt64) : Int32
end

@[Link(ldflags: "`command -v pkg-config > /dev/null && pkg-config --libs glib-2.0 gio-2.0 2>/dev/null || printf %s '-lglib-2.0 -lgio-2.0'`")]
lib LibGIO
  fun g_memory_input_stream_new_from_data(data : Void*, len : LibC::SizeT, destroy : Void*) : Void*
  fun g_error_new_literal(domain : UInt32, code : Int32, message : UInt8*) : Void*
end

@[Link(ldflags: "`command -v pkg-config > /dev/null && pkg-config --libs glib-2.0 2>/dev/null || printf %s '-lglib-2.0'`")]
lib LibGLib
  fun g_timeout_add(interval : UInt32, function : Void*, data : Void*) : UInt32
  fun g_source_remove(tag : UInt32) : Int32
end
