require "io/buffered"

# Monkey patch to overcome ICE `BUG: `def fill_buffer`, this seems to be triggered
# 1. Any code path that calls read_char (or peek/read) on a generic IO reference
# 2. A top-level (not module-nested) class that includes IO::Buffered with a raising unbuffered_read
# 3. A default argument that forces compilation of the above
#
# :nodoc:
module IO::Buffered
  # Add missing return type makes compiler happy
  private def fill_buffer : Nil
    in_buffer = in_buffer()
    size = unbuffered_read(Slice.new(in_buffer, @buffer_size)).to_i
    @in_buffer_rem = Slice.new(in_buffer, size)
  end
end
