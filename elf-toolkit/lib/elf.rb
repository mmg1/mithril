require 'bundler'
require 'andand'
require_relative 'elf_enums'
require_relative 'elf_structs'

require 'pp'
require 'set'
require 'segment_tree'
def enum(name, type, enum_class )         # To be done
  klass = Class.new BinData::Primitive  do
    type value
    def get
      value
    end
    def set(v)
      raise RuntimeError.new "#{v} is not an acceptable value (#{enum_class.acceptable_values})"  unless
        enum_class.acceptable_values.include? v
      value = v
    end
  end
end
def expect_value(desc,is,should)
  raise RuntimeError.new "Invalid #{desc}, expected #{should} instead of #{is}" if is != should
end

module Elf 
  DT = ElfFlags::DynamicType
  SHT = ElfFlags::SectionType
  ET = ElfFlags::Type
  class StringTable
    def initialize(data)
      expect_value "First byte of string table", data.bytes.first, 0
      @data = StringIO.new(data)
    end
    def [](offset)
      @data.seek offset
      obj = BinData::Stringz.new
      obj.read(@data)
      obj.snapshot
    end
  end
  class NilStringTable
    def [](offset)
      return ""
    end
  end 
  class Dynamic
    attr_accessor :bind_now, :symbolic, :needed, :init, :fini, :pltgot, :debug_val, :extra_dynamic
  end
  class ProgBits
    attr_accessor :data,:name, :addr, :flags, :align, :entsize
    def initialize(name,shdr,data)
      @data = StringIO.new(data)
      @name = name
      @addr = shdr.vaddr
      @flags = shdr.flags
      expect_value "PROGBITS link", shdr.link, 0
      expect_value "PROGBITS info", shdr.info, 0
      @align = shdr.addralign
      @entsize = shdr.entsize # Expect 0 for now?
      #      expect_value "PROGBITS entsize", @entsize,0
      expect_value "Progbits must be full present", @data.size, shdr.siz
    end
    def sect_type
      SHT::SHT_PROGBITS
    end
    def size
      @data.size
    end
  end
  class NoBits
    attr_accessor :name, :addr, :flags, :align
    def initialize(name,shdr)
      @name = name
      @addr = shdr.vaddr
      @flags = shdr.flags
      expect_value "NOBITS link", shdr.link, 0
      expect_value "NOBITS info", shdr.info, 0
      @align = shdr.addralign
      @entsize = shdr.entsize # Expect 0 for now?
      @size = shdr.siz
      #      expect_value "PROGBITS entsize", @entsize,0
    end
    def data
      StringIO.new("")
    end
    def sect_type
      SHT::SHT_NOBITS
    end
    def entsize
      1
    end
    def size
      @size
    end
  end
  class Symbol #All values here are section offsets
    attr_accessor :name, :section,:type, :sectoffset, :bind, :size,:is_dynamic
    def initialize(name,section,type,sectoffset, bind,size)
      @name,@section, @type, @sectoffset, @bind, @size = name,section,type,sectoffset, bind,size
      @is_dynamic = false
    end
  end
  class Relocation
    attr_accessor :section, :offset, :type, :symbol, :addend
    attr_accessor :is_dynamic #false for static, true otherwise.
    def initialize
      @is_dynamic = false
    end
  end
  class ElfFile
    attr_accessor :filetype, :machine, :entry, :flags, :version
    attr_accessor :progbits, :nobits, :dynamic, :symbols, :relocations
    attr_accessor :notes, :bits, :endian
  end
  class Parser
    attr_reader :file
    def initialize(string)
      @data = StringIO.new(string)
      @file = ElfFile.new
      ident = ElfStructs::ElfIdentification.read(@data)
      print ident.snapshot.inspect
      raise RuntimeError.new "Invalid ELF version #{ident.id_version}" if ident.id_version != ElfFlags::Version::EV_CURRENT
      case ident.id_class
      when ElfFlags::IdentClass::ELFCLASS64
        @file.bits = 64
      when ElfFlags::IdentClass::ELFCLASS32
        @file.bits = 32
      else
        RuntimeError.new "Invalid ELF class #{ident.id_class}"
      end
      case ident.id_data
      when ElfFlags::IdentData::ELFDATA2LSB
        @file.endian = :little
      when ElfFlags::IdentData::ELFDATA2MSB
        @file.endian = :big
      else
        RuntimeError.new  "Invalid ELF endianness #{ident.id_data}"
      end
      @factory = ElfStructFactory.instance(@file.endian,@file.bits)
      parse_with_factory()
    end
    def self.from_file(filename)
      contents = IO.read(filename)
      Parser.new(contents).file
    end
    private
    def unique_section(sects, type)
      if sects.include? type
        expect_value "Number of #{type} sections", sects[type].size, 1
        return sects[type].first
      else
        return nil
      end
    end
    def safe_strtab(index)
      if(index ==0)
        NilStringTable.new()
      else
        hdr = @shdrs[index]
        expect_value "STRTAB type", hdr.type, ElfFlags::SectionType::SHT_STRTAB
        @data.seek hdr.off
        @unparsed_sections.delete index
        StringTable.new(@data.read(hdr.siz))
      end
    end
    def parse_symtable(sect,strtab)
      return [] if sect.nil?
      expect_value "Size of symbol table entry", @factory.sym.new.num_bytes, sect.entsize
      @data.seek sect.off
      @unparsed_sections.delete sect.index
      BinData::Array.new( :type=> @factory.sym, :initial_length => sect.siz / sect.entsize).read(@data).map do |sym|
        #TODO: find appropriate section
        Symbol.new(strtab[sym.name],sym.shndx.to_i, sym.type.to_i, sym.val.to_i, sym.binding.to_i, sym.siz.to_i)
      end
    end
    def parse_nobits(shdr)
      @unparsed_sections.delete shdr.index
      NoBits.new(@shstrtab[shdr.name],shdr)
    end
    def parse_progbits(shdr)
      @data.seek shdr.off
      @unparsed_sections.delete shdr.index
      expect_value "PROGBITS link",shdr.link,0
      ProgBits.new(@shstrtab[shdr.name], shdr,  @data.read(shdr.siz))
    end
    DYNAMIC_FLAGS =            {
      DT::DT_TEXTREL=>:@textrel,
      DT::DT_BIND_NOW => :@bind_now,
      DT::DT_SYMBOLIC => :@symbolic
    }
    def parse_rel_common(relocations,sect_idx,symtab_idx, uses_addresses)
      case @shdrs[symtab_idx].type.to_i
      when SHT::SHT_DYNSYM
        symtab= @dynsym
      when SHT::SHT_SYMTAB
        symtab= @symtab
      else
        raise ArgumentError.new "Invalid link field #{symtab_idx} in relocation section"
      end
      if sect_idx == 0 and uses_addresses
        applies_to = nil
      else
        applies_to = @progbits_by_index[sect_idx]
        raise ArgumentError.new "Section index #{sect_idx} not referring to PROGBITS for relocation table" if applies_to.nil?
      end
      relocations.map {|rel_entry|
        Relocation.new.tap { |rel|
          if  uses_addresses
            rel.section = @relocatable_sections.find(rel_entry.off.to_i).andand(&:value)
            print "Warning: Invalid relocation address 0x#{rel_entry.off.snapshot.to_s(16)}\n" unless rel.section
            rel.offset = rel_entry.off - rel.section.addr
          else
            rel.section = applies_to
            rel.offset = rel_entry.off
          end
          rel.type = @factory.rel_info_type(rel_entry.info)
          rel.symbol = symtab[ @factory.rel_info_sym(rel_entry.info)]
          rel.addend = rel_entry.addend
        }
      }
    end

    def parse_rela(shdr,has_addrs)
      @unparsed_sections.delete shdr.index
      @data.seek shdr.off
      expect_value "RELA entsize", shdr.entsize, @factory.rela.new.num_bytes
      rela = BinData::Array.new(:type => @factory.rela, :initial_length => shdr.siz/shdr.entsize).read(@data)
      parse_rel_common(rela,shdr.info, shdr.link,has_addrs)
    end
    def parse_rel(shdr,has_addrs)
      @unparsed_sections.delete shdr.index
      @data.seek shdr.off
      expect_value "REL entsize", shdr.entsize, @factory.rel.new.num_bytes
      rela = BinData::Array.new(:type => @factory.rel, :initial_length => shdr.siz/shdr.entsize).read(@data)
      parse_rel_common(rela,shdr.info, shdr.link,has_addrs)
    end
    def parse_dynamic(shdr)
      retval = Dynamic.new

      @data.seek shdr.off
      #TODO: find unused dynamic entries
      expect_value "Size of dynamic entry", @factory.dyn.new.num_bytes, shdr.entsize
      dynamic = BinData::Array.new(:type=> @factory.dyn, :initial_length => shdr.siz/ shdr.entsize).read(@data)
      @unparsed_sections.delete shdr.index
      by_type = dynamic.group_by {|x| x.tag.to_i}
      expect_unique = lambda do |sym,optional| # Validates that either one
        # or zero entries of this type exist, returning the one entry
        # if it exists
        if(by_type.include? sym)
          expect_value  "Dynamic entry #{sym} count", by_type[sym].size,1
          by_type[sym].first
        else
          if(optional)
            nil
          else
            raise ArgumentError.new "Missing mandatory dynamic entry #{sym}"
          end
        end
      end


      expect_value "DT_NULL", dynamic.last, @factory.dyn.new()

      by_type.delete DT::DT_NULL

      expect_unique.call DT::DT_STRTAB,false
      expect_unique.call DT::DT_STRSZ,false  #TODO: check that this a strtab and get a strtab
      strtab_hdr= @sect_types[SHT::SHT_STRTAB].group_by(&:vaddr)[by_type[DT::DT_STRTAB].first.val].andand(&:first)

      expect_value "Some STRTAB section should be mapped at DT_STRTAB", strtab_hdr.nil?,false
      by_type.delete DT::DT_STRTAB
      expect_value "STRSZ", by_type[DT::DT_STRSZ].first.val, strtab_hdr.siz
      by_type.delete DT::DT_STRSZ
      @dynstr = safe_strtab(strtab_hdr.index)

      expect_unique.call DT::DT_SYMENT, false
      expect_value "Dynamic SYMENT",by_type[DT::DT_SYMENT].first.val,  @factory.sym.new.num_bytes
      by_type.delete DT::DT_SYMENT
      expect_unique.call DT::DT_SYMTAB, false
      expect_value "Dynamic symbol table needs to be mapped", by_type[DT::DT_SYMTAB].first.val,@sect_types[SHT::SHT_DYNSYM].first.vaddr
      by_type.delete DT::DT_SYMTAB
      expect_unique.call DT::DT_HASH, true# We totally ignore the hash
      by_type.delete DT::DT_HASH
      retval.needed = []
      by_type[DT::DT_NEEDED].each do |needed|
        retval.needed << @dynstr[needed.val]
      end
      by_type.delete DT::DT_NEEDED

      DYNAMIC_FLAGS.each do |tag, var|
        val  = false
        expect_unique.call(tag,true) { |x| val = true}
        instance_variable_set(var,val)
        by_type.delete tag
      end


      progbits_by_addr = @progbits.group_by(&:addr) #TODO: check
      #that vaddrs don't overlap

      expect_unique.call(DT::DT_INIT,true).andand { |init|
        expect_value "DT_INIT should point to a valid progbits section",
        progbits_by_addr.include?(init.val), true

        retval.init = progbits_by_addr[init.val].first
      }
      by_type.delete DT::DT_INIT
      expect_unique.call(DT::DT_FINI,true).andand { |init|
        expect_value "DT_FINI should point to a valid progbits section",
        progbits_by_addr.include?(init.val), true

        retval.fini = progbits_by_addr[init.val].first
      }
      by_type.delete DT::DT_FINI
      expect_unique.call(DT::DT_PLTGOT,true).andand { |init|
        expect_value "DT_PLTGOT should point to a valid progbits section",
        progbits_by_addr.include?(init.val), true

        retval.pltgot = progbits_by_addr[init.val].first
      }#TODO: check processor supplements
      by_type.delete DT::DT_PLTGOT

      #TODO: write 'expect_group'
      expect_unique.call(DT::DT_RELA,true).andand{ |rela|
        x= @sect_types[SHT::SHT_RELA].group_by{|x| x.vaddr.to_i}
        expect_value "DT_RELA should point to a valid relocation section", x.include?(rela.val), true
        #assert that no overlap?
        reladyn_hdr = x[rela.val].first #TODO: Use parsed relocations!
        expect_unique.call(DT::DT_RELAENT,false).andand {|relaent|
          expect_value "DT_RELAENT size", relaent.val, @factory.rela.new.num_bytes
        }
        expect_unique.call(DT::DT_RELASZ,false).andand {|relasz|
          expect_value "DT_RELASZ", relasz.val, reladyn_hdr.siz
        }
        @relocation_sections[reladyn_hdr.index].each{|rel| rel.is_dynamic = true}
      }
      #TODO: maybe use eval to delete duplication?
      expect_unique.call(DT::DT_REL,true).andand{ |rela|
        x= @sect_types[SHT::SHT_REL].group_by{|x| x.vaddr.to_i}
        expect_value "DT_REL should point to a valid relocation section", x.include?(rela.val), true
        reladyn_hdr = x[rela.val] #TODO: Use parsed relocations!
        expect_unique.call(DT::DT_RELENT,false).andand {|relaent|
          expect_value "DT_RELENT size", relaent.val, @factory.rela.new.num_bytes
        }
        expect_unique.call(DT::DT_RELSZ,false).andand {|relasz|
          expect_value "DT_RELSZ", relasz.val, reladyn_hdr.siz
        }
        @relocation_sections[reladyn_hdr.index].each{|rel| rel.is_dynamic = true}
      }
      [DT::DT_RELA, DT::DT_RELAENT, DT::DT_RELASZ, DT::DT_REL, DT::DT_RELENT, DT::DT_RELSZ].each {|x|  by_type.delete x}
      #Parse RELA.plt or REL.plt
      expect_unique.call(DT::DT_JMPREL,true).andand{ |rela| #TODO:Make
        #this better too!!!
        expect_unique.call(DT::DT_PLTREL,false).andand {|pltrel|
          if pltrel.val == DT::DT_RELA
            type = SHT::SHT_RELA
          elsif pltrel.val == DT::DT_REL
            type = SHT::SHT_REL
          else
            raise ArgumentError.new "Invalid DT_PLTREL"
          end
          x= @sect_types[type].group_by{|x| x.vaddr.to_i}
          expect_value "DT_PLREL should point to a valid relocation section", x.include?(rela.val), true
          reladyn_hdr = x[rela.val].first
          #TODO: Use parsed      #relocations!
          expect_unique.call(DT::DT_PLTRELSZ,false).andand {|relasz|
            expect_value "DT_PLTRELSZ", relasz.val, reladyn_hdr.siz
          }
          @relocation_sections[reladyn_hdr.index].each{|rel| rel.is_dynamic = true}
          by_type.delete DT::DT_PLTRELSZ
        }
        by_type.delete DT::DT_PLTREL
      }
      by_type.delete DT::DT_JMPREL

      retval.debug_val = []
      by_type[DT::DT_DEBUG].each {|x| retval.debug_val << x}
      by_type.delete DT::DT_DEBUG

      #TODO: gnu extensions
      retval.extra_dynamic = by_type.values.flatten
      unless by_type.empty?
        print "Warning, unparsed dynamic entries \n"
        pp by_type
      end
      retval
    end
    def parse_note(note)
      @data.seek note.off
      @unparsed_sections.delete @data
      @factory.note.read(@data).tap {|n|
        expect_value "Note size",n.num_bytes, note.siz
        n.section_name = @shstrtab[note.name] rescue nil
      }
    end
    PT = ElfFlags::PhdrType
    def parse_phdrs()
      #TODO: validate flags
      by_type = @phdrs.group_by{|x| x.type.to_i}
      by_type.delete PT::PT_NULL
      process_unique = lambda do |sym| # Validates that either one
        # or zero entries of this type exist, returning the one entry
        # if it exists
        if(by_type.include? sym)
          expect_value  "PHDR #{sym} count", by_type[sym].size,1
          by_type[sym].first.tap { by_type.delete sym }
        else
          nil
        end
      end

      process_unique.call(PT::PT_PHDR).andand do |pt_phdr|
        expect_value "PHDR offset",pt_phdr.off, @hdr.phoff
        expect_value "PHDR size",pt_phdr.filesz, @hdr.phnum * @hdr.phentsize
      end

      by_type.delete PT::PT_LOAD # TODO:: validate range and that
      # section vaddr is correct!
=begin all notes go into one or multiple program headers.
      by_type[PT::PT_NOTE].each {|note|
        expect_value "SHT_NOTE at this address",
        @sect_types[SHT::SHT_NOTE].find{|n| note.vaddr.to_i == n.vaddr.to_i}.andand {|n|
          [n.off.to_i,n.siz.to_i]
        }, [note.off.to_i,note.filesz.to_i]   }
=end
      by_type.delete PT::PT_NOTE

      process_unique.call(PT::PT_INTERP).andand do |pt_interp| #Technically
        #not needed according to spec, INTERP doesn't need to have its
        #own section. Instead just check what is at that vaddr
        interp_section = @progbits.select {|x| x.addr  == pt_interp.vaddr.to_i}.first
        expect_value ".interp section", interp_section.nil?, false
        @interp = interp_section.data.read
      end
      process_unique.call(PT::PT_DYNAMIC).andand do |pt_dynamic|
        dynamic_section = @sect_types[SHT::SHT_DYNAMIC].first
        expect_value "PT_dynamic address", pt_dynamic.vaddr, dynamic_section.vaddr
        expect_value "PT_dynamic offset" , pt_dynamic.off, dynamic_section.off
        expect_value "PT_dynamic size", pt_dynamic.filesz, dynamic_section.siz
      end
      @extra_phdrs  = by_type.values.flatten
      unless(@extra_phdrs.empty?)
        print "Unparsed PHDR\n"
        pp @extra_phdrs
      end
    end
    def parse_with_factory()
      @data.rewind
      @hdr = @factory.hdr.read(@data)
      @file.filetype = @hdr.type
      @file.machine = @hdr.machine
      @file.version = @hdr.version # Shouldn't this always be the current one
      @file.flags = @hdr.flags
      @file.entry = @hdr.entry
      expect_value "ELF version",@file.version, ElfFlags::Version::EV_CURRENT
      #pp hdr.snapshot

      expect_value "PHT size", @factory.phdr.new.num_bytes, @hdr.phentsize
      @data.seek @hdr.phoff
      @phdrs = BinData::Array.new(:type => @factory.phdr, :initial_length => @hdr.phnum)
      @phdrs.read(@data)


      @data.seek @hdr.shoff
      @shdrs = BinData::Array.new(:type => @factory.shdr, :initial_length => @hdr.shnum)
      @shdrs.read(@data)
      @unparsed_sections = Set.new []
      expect_value "SHT size", @shdrs[0].num_bytes, @hdr.shentsize
      @shstrtab = safe_strtab(@hdr.shstrndx)

      @shdrs.to_enum.with_index.each do |elem, i|
        elem.index = i
        @unparsed_sections.add i
      end


      #Keep a hash of sections by type
      @sect_types = @shdrs.group_by {|x| x.type.to_i}
      #TODO: keep track which    #sections we have already parsed to find unparsed sections
      @progbits_by_index = Hash.new.tap{|h| @sect_types[SHT::SHT_PROGBITS].each { |s| h[s.index] = parse_progbits(s)} }
      @progbits = @progbits_by_index.values
      @file.progbits = @progbits

      @nobits = @sect_types[SHT::SHT_NOBITS].map{ |x| parse_nobits x}
      @file.nobits = @nobits

      @relocatable_sections = SegmentTree.new(Hash.new.tap{|h|
                                                (@progbits + @nobits).each{ |pb|
                                                  h[(pb.addr)..(pb.addr + pb.size)]=pb
                                                }
                                              })

      parse_phdrs()
      @symtab = unique_section(@sect_types, ElfFlags::SectionType::SHT_SYMTAB).andand {|symtab| parse_symtable symtab, safe_strtab(symtab.link); @unparsed_sections.delete  }
      @dynsym = unique_section(@sect_types, ElfFlags::SectionType::SHT_DYNSYM).andand {|symtab| parse_symtable symtab, safe_strtab(symtab.link) }
      
      @file.symbols = Hash.new.tap{|h| (@symtab || []).each{|sym| h[sym.name] = sym}}
      (@dynsym|| []).each {|sym|
        sym.is_dynamic = true
        if @file.symbols.include? sym.name
          staticsym =  @file.symbols[sym.name]
          expect_value "Dynamic #{sym.name} value", sym.sectoffset, staticsym.sectoffset
          expect_value "Dynamic #{sym.name} value", sym.section, staticsym.section
          expect_value "Dynamic #{sym.name} size", sym.size,  staticsym.size
          staticsym.is_dynamic = true
        else
          @file.symbols[sym.name] = sym
        end
      }    
      rels_addrs = [ET::ET_EXEC, ET::ET_DYN].include? @hdr.type
      rel =  (@sect_types[SHT::SHT_RELA] || []).map {|rela| [rela.index, parse_rela(rela,rels_addrs)] }+ (@sect_types[SHT::SHT_REL] || []).map{|rel| [rela.index,parse_rel(rela,rels_addrs)]}

      @relocation_sections = Hash[*rel.flatten(1)]
   

      @file.dynamic = unique_section(@sect_types, ElfFlags::SectionType::SHT_DYNAMIC).andand{|dynamic| parse_dynamic dynamic}
      
      

      #TODO: gnu extensions, in particular gnu_hash

      @file.notes = (@sect_types[SHT::SHT_NOTE] || []).map{|note| parse_note note}
      #TODO: expect non-nil dynamic for some types
      @file.relocations = @relocation_sections.values.flatten
      #TODO: Validate flags
      #TODO: Validate header?
      
    end
  end

module Writer
  class StringTable #Replace with compacting string table
    attr_reader :buf
    def initialize 
      @buf = StringIO.new("\0")
      @strings = {} #TODO: Do substring matching, compress the string
      #table.
      # Actually, make all string tables except dynstr one, might save
      # a bit 
    end
    def add_string(string) 
      unless @strings.include? string
        @strings[string] =  @buf.tell.tap {|x| 
          BinData::Stringz::new(string).write(@buf)
        }
      end
      @strings[string]
    end      
  end
  #TODO: Needs a unique class for 'allocatable' sections. 
  #Then just sort, and write them out
  class Writer #TODO: Completely refactor this
      PAGESIZE = 2^16  #KLUDGE: largest pagesize , align everything to
    #pagesizes 
    def initialize(file,factory)
      @factory = factory
      @file = file
      @shstrtab = StringTable.new()
      @shdrs= BinData::Array::new(type: @factory.shdr,initial_length: 0)
      @phdrs= BinData::Array::new(type: @factory.phdr,initial_length: 0)
      @buf = StringIO.new()
      write_to_buf
    end
    def self.to_file(filename,elf)
      factory = ElfStructFactory.instance(elf.endian,elf.bits) 
      writer = Writer.new(elf,factory)
      IO.write filename,writer.buf.string
    end
    attr_reader :buf
    private
    def add_section(name,type,flags,vaddr,off,siz,link,info,align,entsize)
      x=  @factory.shdr.new
      x.name   = @shstrtab.add_string(name)
      x.type   = type
      x.flags  = flags
      x.vaddr  = vaddr
      x.off    = off
      x.siz    = siz
      x.link   = link
      x.info   = info
      x.addralign  = align
      x.entsize= entsize
      @shdrs<< x 
      @shdrs.size - 1
    end
    def align(bytes)
      @buf.seek bytes - (@buf.tell % bytes), IO::SEEK_CUR
    end
    def write_progbits
      
      write_out=(@file.progbits + @file.nobits).sort_by{|x| x.addr}
      write_out.each do |sect| 
        align sect.align
        off = @buf.tell
        @buf.write sect.data.string
        add_section sect.name, sect.sect_type, sect.flags, sect.addr, off, @buf.size,0,0,sect.align, sect.entsize
      end
    end
    def write_note
      align 4
      @file.notes do |note|
        note.write(@buf) # Luckily, notes are stored as is.
        note_name = note.section_name || ".note.unk#{note.hash}" 
        # TODO:        # MD5 of contents?
        add_section note_name, SHT::NOTE, note_flags, 0, off, note.num_bytes,0,0,note_align, sect.entsize
      end
      #TODO:Add PHDR
      #      @file.note.each do |
    end
    
    def write_dynsym
    end # Produce a hash and a GNU_HASH as well
    def write_dynamic
    end # Write note, etc for the above
    def write_phdr(filehdr)
      #Assemble phdrs
    end 
    def write_reladyn()
    end
    def write_shstrtab() # Last section written
     
      name = ".shstrtab"
      @shstrtab.add_string name
      idx = add_section name, SHT::SHT_STRTAB, 0, 0, @buf.tell, @shstrtab.buf.size,0,0,0,0

      @buf.write  @shstrtab.buf.string
      idx
    end
    def write_shdr(filehdr)
      #      @buf.align 8 # See if this has a performance advantage/
      #      makes less tools crash 
      filehdr.shstrndx = write_shstrtab
      filehdr.shoff = @buf.tell
      filehdr.shentsize = @shdrs[0].num_bytes
      filehdr.shnum = @shdrs.size
      @shdrs.write buf
    end

    def write_headers
      hdr = @factory.hdr.new
      case @file.endian
        when :big
        hdr.ident.id_data =  ElfFlags::IdentData::ELFDATA2MSB 
        when :little
        hdr.ident.id_data =  ElfFlags::IdentData::ELFDATA2LSB 
        else 
        raise ArgumentError.new "Invalid endianness"
      end
      case @file.bits 
      when 64 
        hdr.ident.id_class = ElfFlags::IdentClass::ELFCLASS64
      when 32
        hdr.ident.id_class = ElfFlags::IdentClass::ELFCLASS32
      else
        raise ArgumentError.new "Invalid class"
      end
      hdr.ident.id_version = ElfFlags::Version::EV_CURRENT
      
      hdr.type = @file.filetype
      hdr.machine = @file.machine
      hdr.version = @file.version
      hdr.entry = @file.entry
      hdr.flags = @file.flags
      
      write_phdr(hdr)
      write_shdr(hdr)
      @buf.seek 0 
      hdr.write @buf
    end
#TODO: Fix things like INTERP
      

    def write_to_buf #Make this memoized
      @buf.seek @factory.hdr.new.num_bytes #Leave space for header.
      #this is pretty bad
      write_progbits 
      write_note
      write_dynsym
      write_reladyn
      write_dynamic
      write_headers
    end

  end
end
end

$parse = Elf::Parser.from_file "/bin/ls"
#pp parse # .instance_variables
##TODO: Do enums as custom records.