class PEdump

  def resource_directory f=@io
    @resource_directory ||=
      if pe(f)
        _read_resource_directory_tree(f)
      elsif ne(f)
        ne(f).resource_directory(f)
      end
  end

  def _read_resource_directory_tree f
    return nil unless pe(f) && pe(f).ioh && f
    res_dir = @pe.ioh.DataDirectory[IMAGE_DATA_DIRECTORY::RESOURCE]
    return [] if !res_dir || (res_dir.va == 0 && res_dir.size == 0)
    res_va = @pe.ioh.DataDirectory[IMAGE_DATA_DIRECTORY::RESOURCE].va
    res_section = @pe.section_table.find{ |t| t.VirtualAddress == res_va }
    unless res_section
      logger.warn "[?] can't find resource section for va=0x#{res_va.to_s(16)}"
      return []
    end
    f.seek res_section.PointerToRawData
    IMAGE_RESOURCE_DIRECTORY.base = res_section.PointerToRawData
    #@resource_data_base = res_section.PointerToRawData - res_section.VirtualAddress
    IMAGE_RESOURCE_DIRECTORY.read(f)
  end

  class Resource < Struct.new(:type, :name, :id, :lang, :file_offset, :size, :cp, :reserved, :data, :valid)
    def bitmap_hdr
      bmp_info_hdr = data.find{ |x| x.is_a?(BITMAPINFOHEADER) }
      raise "no BITMAPINFOHEADER for #{self.type} #{self.name}" unless bmp_info_hdr

      bmp_info_hdr.biHeight/=2 if %w'ICON CURSOR'.include?(type)

      colors_used = bmp_info_hdr.biClrUsed
      colors_used = 2**bmp_info_hdr.biBitCount if colors_used == 0 && bmp_info_hdr.biBitCount < 16

      # XXX: one byte in each color is unused!
      @palette_size = colors_used * 4 # each color takes 4 bytes

      # scanlines are DWORD-aligned and padded to DWORD-align with zeroes
      # XXX: some data may be hidden in padding bytes!
      scanline_size = bmp_info_hdr.biWidth * bmp_info_hdr.biBitCount / 8
      scanline_size += (4-scanline_size%4) if scanline_size % 4 > 0

      @imgdata_size = scanline_size * bmp_info_hdr.biHeight
      "BM" + [
        BITMAPINFOHEADER::SIZE + 14 + @palette_size + @imgdata_size,
        0,
        BITMAPINFOHEADER::SIZE + 14 + @palette_size
      ].pack("V3") + bmp_info_hdr.pack
    ensure
      bmp_info_hdr.biHeight*=2 if %w'ICON CURSOR'.include?(type)
    end

    # only valid for types BITMAP, ICON & CURSOR
    def restore_bitmap src_fname
      File.open(src_fname, "rb") do |f|
        parse f
        if data.first == "PNG"
          "\x89PNG" +f.read(self.size-4)
        else
          bitmap_hdr + f.read(@palette_size + @imgdata_size)
        end
      end
    end

    def bitmap_mask src_fname
      File.open(src_fname, "rb") do |f|
        parse f
        bmp_info_hdr = bitmap_hdr
        bitmap_size = BITMAPINFOHEADER::SIZE + @palette_size + @imgdata_size
        return nil if bitmap_size >= self.size

        mask_size = self.size - bitmap_size
        f.seek file_offset + bitmap_size

        bmp_info_hdr = BITMAPINFOHEADER.new(*bmp_info_hdr[14..-1].unpack(BITMAPINFOHEADER::FORMAT))
        bmp_info_hdr.biBitCount = 1
        bmp_info_hdr.biCompression = bmp_info_hdr.biSizeImage = 0
        bmp_info_hdr.biClrUsed = bmp_info_hdr.biClrImportant = 2

        palette = [0,0xffffff].pack('V2')
        @palette_size = palette.size

        "BM" + [
          BITMAPINFOHEADER::SIZE + 14 + @palette_size + mask_size,
          0,
          BITMAPINFOHEADER::SIZE + 14 + @palette_size
        ].pack("V3") + bmp_info_hdr.pack + palette + f.read(mask_size)
      end
    end

    # also sets the file position for restore_bitmap next call
    def parse f
      raise "called parse with type not set" unless self.type
      #return if self.data

      self.data = []
      case type
      when 'BITMAP','ICON'
        f.seek file_offset
        if f.read(4) == "\x89PNG"
          data << 'PNG'
        else
          f.seek file_offset
          data << BITMAPINFOHEADER.read(f)
        end
      when 'CURSOR'
        f.seek file_offset
        data << CURSOR_HOTSPOT.read(f)
        data << BITMAPINFOHEADER.read(f)
      when 'GROUP_CURSOR'
        f.seek file_offset
        data << CUR_ICO_HEADER.read(f)
        nRead = CUR_ICO_HEADER::SIZE
        data.last.wNumImages.to_i.times do
          if nRead >= self.size
            PEdump.logger.error "[!] refusing to read CURDIRENTRY beyond resource size"
            break
          end
          data  << CURDIRENTRY.read(f)
          nRead += CURDIRENTRY::SIZE
        end
      when 'GROUP_ICON'
        f.seek file_offset
        data << CUR_ICO_HEADER.read(f)
        nRead = CUR_ICO_HEADER::SIZE
        data.last.wNumImages.to_i.times do
          if nRead >= self.size
            PEdump.logger.error "[!] refusing to read ICODIRENTRY beyond resource size"
            break
          end
          data  << ICODIRENTRY.read(f)
          nRead += ICODIRENTRY::SIZE
        end
      when 'STRING'
        f.seek file_offset
        16.times do
          break if f.tell >= file_offset+self.size
          nChars = f.read(2).to_s.unpack('v').first.to_i
          t =
            if nChars*2 + 1 > self.size
              # TODO: if it's not 1st string in table then truncated size must be less
              PEdump.logger.error "[!] string size(#{nChars*2}) > stringtable size(#{self.size}). truncated to #{self.size-2}"
              f.read(self.size-2)
            else
              f.read(nChars*2)
            end
          data <<
            begin
              t.force_encoding('UTF-16LE').encode!('UTF-8')
            rescue
              t.force_encoding('ASCII')
              tt = t.size > 0x10 ? t[0,0x10].inspect+'...' : t.inspect
              PEdump.logger.error "[!] cannot convert #{tt} to UTF-16"
              [nChars,t].pack('va*')
            end
        end
        # XXX: check if readed strings summary length is less than resource data length
      when 'VERSION'
        f.seek file_offset
        data << PEdump::VS_VERSIONINFO.read(f)
      end

      data.delete_if do |x|
        valid = !x.respond_to?(:valid?) || x.valid?
        PEdump.logger.warn "[?] ignoring invalid #{x.class}" unless valid
        !valid
      end
    ensure
      validate
    end

    def validate
      self.valid =
        case type
        when 'BITMAP','ICON','CURSOR'
          data.any?{ |x| x.is_a?(BITMAPINFOHEADER) && x.valid? } || data.first == 'PNG'
        else
          true
        end
    end
  end

  STRING = Struct.new(:id, :lang, :value)

  def strings f=@io
    r = []
    Array(resources(f)).find_all{ |x| x.type == 'STRING'}.each do |res|
      res.data.each_with_index do |string,idx|
        r << STRING.new( ((res.id-1)<<4) + idx, res.lang, string ) unless string.empty?
      end
    end
    r
  end

  # see also http://www.informit.com/articles/article.aspx?p=1186882 about icons format

  class BITMAPINFOHEADER < create_struct 'V3v2V6',
    :biSize,          # BITMAPINFOHEADER::SIZE
    :biWidth,
    :biHeight,
    :biPlanes,
    :biBitCount,
    :biCompression,
    :biSizeImage,
    :biXPelsPerMeter,
    :biYPelsPerMeter,
    :biClrUsed,
    :biClrImportant

    def valid?
      self.biSize == 40
    end
  end

  # http://www.devsource.com/c/a/Architecture/Resources-From-PE-I/2/
  CUR_ICO_HEADER = create_struct('v3',
    :wReserved, # always 0
    :wResID,    # always 2
    :wNumImages # Number of cursor images/directory entries
  )

  CURDIRENTRY = create_struct 'v4Vv',
    :wWidth,
    :wHeight, # Divide by 2 to get the actual height.
    :wPlanes,
    :wBitCount,
    :dwBytesInImage,
    :wID

  CURSOR_HOTSPOT = create_struct 'v2', :x, :y

  ICODIRENTRY = create_struct 'C4v2Vv',
    :bWidth,
    :bHeight,
    :bColors,
    :bReserved,
    :wPlanes,
    :wBitCount,
    :dwBytesInImage,
    :wID

  ROOT_RES_NAMES = [nil] + # numeration is started from 1
    %w'CURSOR BITMAP ICON MENU DIALOG STRING FONTDIR FONT ACCELERATORS RCDATA' +
    %w'MESSAGETABLE GROUP_CURSOR' + [nil] + %w'GROUP_ICON' + [nil] +
    %w'VERSION DLGINCLUDE' + [nil] + %w'PLUGPLAY VXD ANICURSOR ANIICON HTML MANIFEST'

  IMAGE_RESOURCE_DIRECTORY_ENTRY = create_struct 'V2',
    :Name, :OffsetToData,
    :name, :data

  IMAGE_RESOURCE_DATA_ENTRY = create_struct 'V4',
    :OffsetToData, :Size, :CodePage, :Reserved

  IMAGE_RESOURCE_DIRECTORY = create_struct 'V2v4',
    :Characteristics, :TimeDateStamp, # 2dw
    :MajorVersion, :MinorVersion, :NumberOfNamedEntries, :NumberOfIdEntries, # 4w
    :entries # manual
  class IMAGE_RESOURCE_DIRECTORY
    class << self
      attr_accessor :base
      alias :read_without_children :read
      def read f, root=true
        if root
          @@loopchk1 = Hash.new(0)
          @@loopchk2 = Hash.new(0)
          @@loopchk3 = Hash.new(0)
        elsif (@@loopchk1[f.tell] += 1) > 1
          PEdump.logger.error "[!] #{self}: loop1 detected at file pos #{f.tell}" if @@loopchk1[f.tell] < 2
          return nil
        end
        read_without_children(f).tap do |r|
          nToRead = r.NumberOfNamedEntries.to_i + r.NumberOfIdEntries.to_i
          r.entries = []
          nToRead.times do |i|
            if f.eof?
              PEdump.logger.error "[!] #{self}: #{nToRead} entries in directory, but got EOF on #{i}-th."
              break
            end
            if (@@loopchk2[f.tell] += 1) > 1
              PEdump.logger.error "[!] #{self}: loop2 detected at file pos #{f.tell}" if @@loopchk2[f.tell] < 2
              next
            end
            r.entries << IMAGE_RESOURCE_DIRECTORY_ENTRY.read(f)
          end
          #r.entries.uniq!
          r.entries.each do |entry|
            entry.name =
              if entry.Name.to_i & 0x8000_0000 > 0
                # Name is an address of unicode string
                f.seek base + entry.Name & 0x7fff_ffff
                nChars = f.read(2).to_s.unpack("v").first.to_i
                begin
                  f.read(nChars*2).force_encoding('UTF-16LE').encode!('UTF-8')
                rescue
                  PEdump.logger.error "[!] #{self} failed to read entry name: #{$!}"
                  "???"
                end
              else
                # Name is a numeric id
                "##{entry.Name}"
              end
            if entry.OffsetToData && f.checked_seek(base + entry.OffsetToData & 0x7fff_ffff)
              if (@@loopchk3[f.tell] += 1) > 1
                PEdump.logger.error "[!] #{self}: loop3 detected at file pos #{f.tell}" if @@loopchk3[f.tell] < 2
                next
              end
              entry.data =
                if entry.OffsetToData & 0x8000_0000 > 0
                  # child is a directory
                  IMAGE_RESOURCE_DIRECTORY.read(f,false)
                else
                  # child is a resource
                  IMAGE_RESOURCE_DATA_ENTRY.read(f)
                end
            end
          end
          @@loopchk1 = @@loopchk2 = @@loopchk3 = nil if root # save some memory
        end
      end
    end
  end

  def _scan_pe_resources f=@io, dir=nil
    dir ||= resource_directory(f)
    return nil unless dir
    dir.entries.map do |entry|
      case entry.data
        when IMAGE_RESOURCE_DIRECTORY
          if dir == @resource_directory # root resource directory
            entry_type =
              if entry.Name & 0x8000_0000 == 0
                # root resource directory & entry name is a number
                ROOT_RES_NAMES[entry.Name] || entry.name
              else
                entry.name
              end
            _scan_pe_resources(f,entry.data).each do |res|
              res.type = entry_type
              res.parse f
            end
          else
            _scan_pe_resources(f,entry.data).each do |res|
              res.name = res.name == "##{res.lang}" ? entry.name : "#{entry.name} / #{res.name}"
              res.id ||= entry.Name if entry.Name.is_a?(Numeric) && entry.Name < 0x8000_0000
            end
          end
        when IMAGE_RESOURCE_DATA_ENTRY
          Resource.new(
            nil,          # type
            entry.name,
            nil,          # id
            entry.Name,   # lang
            #entry.data.OffsetToData + @resource_data_base,
            va2file(entry.data.OffsetToData),
            entry.data.Size,
            entry.data.CodePage,
            entry.data.Reserved
          )
        else
          logger.error "[!] invalid resource entry: #{entry.data.inspect}"
          nil
      end
    end.flatten.compact
  end
end
