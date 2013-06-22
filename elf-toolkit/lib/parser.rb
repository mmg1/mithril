require_relative 'elf'

$UNSAFE_PARSER = ! ENV['HOWDY_NEIGHBOURS_BX'].nil? # shoutout to one
# of the best ELF hackers on the block. 

def expect_value(desc,is,should)
  unless $UNSAFE_PARSER
    raise RuntimeError.new "Invalid #{desc}, expected #{should} instead of #{is}" if is != should
  end
end

module Elf
  module Parser
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

        if sym.shndx.to_i == 0  || sym.shndx.to_i == SHN::SHN_ABS || ([ STT::STT_SECTION, STT::STT_OBJECT].include? sym.type.to_i)
          #TODO: Find section by vaddr
          section =  nil
          value = sym.val.to_i
        else
          section = @bits_by_index[sym.shndx.to_i] 
          if([ET::ET_EXEC, ET::ET_DYN].include? @file.filetype)
            value = sym.val.to_i - section.addr #TODO: Only if absolute.
          else 
            value = sym.val.to_i
          end
          expect_value "Section index #{sym.shndx.to_i} in symbol should be in progbits", false, section.nil?
        end
        
        Symbol.new(strtab[sym.name],section, sym.type.to_i, value, sym.binding.to_i, sym.siz.to_i)
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
      ProgBits.new(@shstrtab[shdr.name], shdr.snapshot,  @data.read(shdr.siz))
    end
    
    def parse_verneed(shdr)
      @versions = {}
      @data.seek shdr.off
      @unparsed_sections.delete shdr.index
      strtab = safe_strtab(shdr.link)
      data = @data.read(shdr.siz)
      # This is the weird, screwed up 'array' implementation that
      # they use
      verneedoff = 0
      shdr.info.to_i.times{ #SHDR.info has number of entries
        data.seek verneedoff
        verneed = @factory.verneed.read(data)
        expect_value "VERNEED version", verneed.version, 1
        file = strtab[verneed.file]
        vernauxoff = verneedoff + verneed.aux
        
        verneed.cnt.times {
          data.seek vernauxoff
          
          vernaux = @factory.verneed.read(data)            
          versionname = strtab[vernaux.name]
          flags = vernaux.flags.to_i
          version = vernaux.other.to_i
          
          @versions[version] = GnuVersion.new(file: file, version: versionname, flags: flags)
          vernauxoff += vernaux.next
        }
        vernauxoff += verneed.next
      } 
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
        applies_to = @bits_by_index[sect_idx]
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
          rel.type = rel_entry.type
          rel.symbol = symtab[ rel_entry.sym]
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
      by_type[DT::DT_DEBUG].each {|x| retval.debug_val << x.val}
      by_type.delete DT::DT_DEBUG

      #TODO: gnu extensions
      retval.extra_dynamic = by_type.values.flatten.map(&:snapshot)
      unless by_type.empty?
        print "Warning, unparsed dynamic entries \n"
        pp by_type
      end
      retval
    end
    def parse_note(note)
      note_name = @shstrtab[note.name] || ".note.unk.#{note.off}"
      @data.seek note.off
      expect_value "Note alignment", note.addralign, NOTE_ALIGN
      expect_value "Note flags", note.flags, NOTE_FLAGS
      expect_value "Note entsize", note.entsize, NOTE_ENTSIZE
      @unparsed_sections.delete @data
      [note_name, @factory.note.read(@data).tap {|n|
         expect_value "Note size",n.num_bytes, note.siz 
      } ]
    end

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
        expect_value "PHD offset",pt_phdr.off, @hdr.phoff
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
        @file.interp = interp_section.data.read
        @progbits.delete interp_section
      end
      process_unique.call(PT::PT_DYNAMIC).andand do |pt_dynamic|
        dynamic_section = @sect_types[SHT::SHT_DYNAMIC].first
        expect_value "PT_dynamic address", pt_dynamic.vaddr, dynamic_section.vaddr
        expect_value "PT_dynamic offset" , pt_dynamic.off, dynamic_section.off
        expect_value "PT_dynamic size", pt_dynamic.filesz, dynamic_section.siz
      end
      @file.extra_phdrs  = by_type.values.flatten
      unless(@file.extra_phdrs.empty?)
        print "Unparsed PHDR\n"
        pp @file.extra_phdrs
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
        unless elem.flags & SHF::SHF_ALLOC
          expect_value "Unallocated section address", elem.vaddr, 0
        end
      end


      #Keep a hash of sections by type
      @sect_types = @shdrs.group_by {|x| x.type.to_i}
      #TODO: keep track which    #sections we have already parsed to find unparsed sections
      @bits_by_index = Hash.new.tap{|h| @sect_types[SHT::SHT_PROGBITS].each { |s| h[s.index] = parse_progbits(s)} }
      @progbits = @bits_by_index.values
      @file.progbits = @progbits

      @nobits = @sect_types[SHT::SHT_NOBITS].map{ |x| parse_nobits(x).tap{|y| y.index = x.index}}
      @nobits.each{|nobit| @bits_by_index[nobit.index] = nobit}
      @file.nobits = @nobits

      @relocatable_sections = SegmentTree.new(Hash.new.tap{|h|
                                                (@progbits + @nobits).each{ |pb|
                                                  h[(pb.addr)..(pb.addr + pb.size)]=pb
                                                }
                                              })

      parse_phdrs()
      @symtab = unique_section(@sect_types, ElfFlags::SectionType::SHT_SYMTAB).andand {|symtab| parse_symtable symtab, safe_strtab(symtab.link) }
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

      @file.notes = Hash[(@sect_types[SHT::SHT_NOTE] || []).map{|note| parse_note note}]
      #TODO: expect non-nil dynamic for some types
      @file.relocations = @relocation_sections.values.flatten
      #TODO: Validate flags
      #TODO: Validate header?
      
    end
  end
  def self.from_file(filename)
    contents = IO.read(filename)
    Parser.new(contents).file
  end
  end
end