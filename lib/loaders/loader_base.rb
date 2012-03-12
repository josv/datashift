# Copyright:: (c) Autotelik Media Ltd 2011
# Author ::   Tom Statter
# Date ::     Aug 2010
# License::   MIT
#
#  Details::  Base class for loaders, providing a process hook which populates a model,
#             based on a method map and supplied value from a file - i.e a single column/row's string value.
#             Note that although a single column, the string can be formatted to contain multiple values.
#
#             Tightly coupled with MethodMapper classes (in lib/engine) which contains full details of
#             a file's column and it's correlated AR associations.
#
module DataShift

  require 'datashift/method_mapper'

  class LoaderBase

    include DataShift::Logging
    include DataShift::Populator
      
    attr_reader :headers

    attr_accessor :method_mapper

    attr_accessor :load_object_class, :load_object
    attr_accessor :current_value, :current_method_detail

    attr_accessor :loaded_objects, :failed_objects

    attr_accessor :options

    # Support multiple associations being added to a base object to be specified in a single column.
    # 
    # Entry represents the association to find via supplied name, value to use in the lookup.
    # Can contain multiple lookup name/value pairs, separated by multi_assoc_delim ( | )
    # 
    # Default syntax :
    #
    #   Name1:value1, value2|Name2:value1, value2, value3|Name3:value1, value2
    #
    # E.G.
    #   Association Properties, has a column named Size, and another called Colour,
    #   and this combination could be used to lookup multiple associations to add to the main model Jumper
    #
    #       Size:small            # => generates find_by_size( 'small' )
    #       Size:large            # => generates find_by_size( 'large' )
    #       Colour:red,green,blue # => generates find_all_by_colour( ['red','green','blue'] )
    #
    #       Size:large|Size:medium|Size:large
    #         => Find 3 different associations, perform lookup via column called Size
    #         => Jumper.properties << [ small, medium, large ]
    #
    def self.name_value_delim
      @name_value_delim ||= ':'
      @name_value_delim
    end

    def self.set_name_value_delim(x)  @name_value_delim = x; end
    # TODO - support embedded object creation/update via hash (which hopefully we should be able to just forward to AR)
    #
    #      |Category|
    #      name:new{ :date => '20110102', :owner = > 'blah'}
    #
    
    
    def self.multi_value_delim
      @multi_value_delim ||= ','
      @multi_value_delim
    end
    
    def self.set_multi_value_delim(x) @multi_value_delim = x; end
    
    # TODO - support multi embedded object creation/update via hash (which hopefully we should be able to just forward to AR)
    #
    #      |Category|
    #      name:new{ :a => 1, :b => 2}|name:medium{ :a => 6, :b => 34}|name:old{ :a => 12, :b => 67}
    #
    def self.multi_assoc_delim
      @multi_assoc_delim ||= '|'
      @multi_assoc_delim
    end


    def self.set_multi_assoc_delim(x) @multi_assoc_delim = x; end

    
    # Options
    #     :instance_methods => true

    def initialize(object_class, object = nil, options = {})
      @load_object_class = object_class

      # Gather names of all possible 'setter' methods on AR class (instance variables and associations)
      DataShift::MethodDictionary.find_operators( @load_object_class, :reload => true, :instance_methods => options[:instance_methods] )

      # Create dictionary of data on all possible 'setter' methods which can be used to
      # populate or integrate an object of type @load_object_class
      DataShift::MethodDictionary.build_method_details(@load_object_class)
      
      @method_mapper = DataShift::MethodMapper.new
      @options = options.clone
      @headers = []

      @default_data_objects ||= {}
      
      @default_values  = {}
      @override_values = {}
      
      @prefixes       = {}
      @postfixes      = {}
      
      reset(object)
    end


    # kinda the derived classes interface - best way in Ruby ?
    def perform_load( input, options = {} )
      raise "WARNING- ABSTRACT METHOD CALLED - Please implement perform_load()"
    end

    
    # Core API - Given a list of free text column names from a file, 
    # map all headers to a method detail containing operator details.
    # 
    # This is then available through @method_mapper.method_details.each
    # 
    # Options:
    #  strict : report any header values that can't be mapped as an error
    #
    def map_headers_to_operators( headers, strict, mandatory = [])
      @headers = headers
      
      begin 
        method_details = @method_mapper.map_inbound_to_methods( load_object_class, @headers )
      rescue => e
        logger.error("Failed to map header row to set of database operators : #{e.inspect}")
        raise MappingDefinitionError, "Failed to map header row to set of database operators"
      end
      
      unless(@method_mapper.missing_methods.empty?)
        puts "WARNING: Following column headings could not be mapped : #{@method_mapper.missing_methods.inspect}"
        raise MappingDefinitionError, "Missing mappings for columns : #{@method_mapper.missing_methods.join(",")}" if(strict)
      end

      unless(@method_mapper.contains_mandatory?(mandatory) )
        @method_mapper.missing_mandatory(mandatory).each { |e| puts "ERROR: Mandatory column missing - expected column '#{e}'" }
        raise MissingMandatoryError, "Mandatory columns missing  - please fix and retry."
      end unless(mandatory.empty?)
    end


    # Process any defaults user has specified, for those columns that are not included in
    # the incoming import format
    def process_missing_columns_with_defaults()
      inbound_ops = @method_mapper.operator_names
      @default_values.each do |dn, dv|     
        assignment(dn, @load_object, dv) unless(inbound_ops.include?(dn))
      end
    end
    
    # Core API - Given a single free text column name from a file, search method mapper for
    # associated operator on base object class.
    # 
    # If suitable association found, process row data and then assign to current load_object
    def find_and_process(column_name, data)
      method_detail = MethodDictionary.find_method_detail( load_object_class, column_name )

      if(method_detail)
        prepare_data(method_detail, data)
        process()
      else
        @load_object.errors.add_base( "No matching method found for column #{column_name}")
      end
    end
    
    
    # Default values can be provided in YAML config file
    #  Format :
    #    Load Class
    #         atttribute: value
    
    def configure_from( yaml_file )

      data = YAML::load( File.open(yaml_file) )
      
      
      # TODO - MOVE DEFAULTS TO OWN MODULE 
      # decorate the loading class with the defaults/ove rides to manage itself
      #   IDEAS .....
      #
      #unless(@default_data_objects[load_object_class])
      #
      #   @default_data_objects[load_object_class] = load_object_class.new
      
      #  default_data_object = @default_data_objects[load_object_class]
      
      
      # default_data_object.instance_eval do
      #  def datashift_defaults=(hash)
      #   @datashift_defaults = hash
      #  end
      #  def datashift_defaults
      #    @datashift_defaults
      #  end
      #end unless load_object_class.respond_to?(:datashift_defaults)
      #end
      
      #puts load_object_class.new.to_yaml
      
      logger.info("Read Datashift loading config: #{data.inspect}")
      
      if(data[load_object_class.name])
        
        deflts = data[load_object_class.name]['datashift_defaults']
        @default_values.merge!(deflts) if deflts
        
        ovrides = data[load_object_class.name]['datashift_overrides']
        @override_values.merge!(ovrides) if ovrides
      end
      
    end
    
    # Set member variables to hold details and value.
    # 
    # Check supplied value, validate it, and if required :
    #   set to any provided default value
    #   prepend or append with any provided extensions
    def prepare_data(method_detail, value)
      
      @current_value = value
      
      @current_method_detail = method_detail
      
      operator = method_detail.operator
      
      override_value(operator)
        
      if((value.nil? || value.to_s.empty?) && default_value(operator))
        @current_value = default_value(operator)
      end
      
      @current_value = "#{prefixes(operator)}#{@current_value}" if(prefixes(operator))
      @current_value = "#{@current_value}#{postfixes(operator)}" if(postfixes(operator))

      @current_value
    end
    

    # Process a value string from a column.
    # Assigning value(s) to correct association on @load_object.
    # Method detail represents a column from a file and it's correlated AR associations.
    # Value string which may contain multiple values for a collection association.
    #
    def process()
      
      if(@current_method_detail.operator_for(:has_many))

        if(@current_method_detail.operator_class && @current_value)

          # there are times when we need to save early, for example before assigning to
          # has_and_belongs_to associations which require the load_object has an id for the join table
        
          save_if_new

          # A single column can contain multiple associations delimited by special char
          # Size:large|Colour:red,green,blue => ['Size:large', 'Colour:red,green,blue']
          columns = @current_value.to_s.split( LoaderBase::multi_assoc_delim)

          # Size:large|Colour:red,green,blue   => generates find_by_size( 'large' ) and find_all_by_colour( ['red','green','blue'] )

          columns.each do |col_str|
            
            find_operator, col_values = "",""
           
            if(@current_method_detail.find_by_operator)
              find_operator, col_values = @current_method_detail.find_by_operator, col_str
            else
              find_operator, col_values = col_str.split(LoaderBase::name_value_delim)
              raise "No key to find #{@current_method_detail.operator} in DB. Expected format key:value" unless(col_values)
            end
            
            find_by_values = col_values.split(LoaderBase::multi_value_delim)

            if(find_by_values.size > 1)

              @current_value = @current_method_detail.operator_class.send("find_all_by_#{find_operator}", find_by_values )

              unless(find_by_values.size == @current_value.size)
                found = @current_value.collect {|f| f.send(find_operator) }
                @load_object.errors.add( @current_method_detail.operator, "Association with key(s) #{(find_by_values - found).inspect} NOT found")
                puts "WARNING: Association with key(s) #{(lookups - found).inspect} NOT found - Not added."
                next if(@current_value.empty?)
              end

            else

              @current_value = @current_method_detail.operator_class.send("find_by_#{find_operator}", find_by_values )

              unless(@current_value)
                @load_object.errors.add( @current_method_detail.operator, "Association with key #{find_by_values} NOT found")
                puts "WARNING: Association with key #{find_by_values} NOT found - Not added."
                next
              end

            end

            # Lookup Assoc's Model done, now add the found value(s) to load model's collection
            @current_method_detail.assign(@load_object, @current_value)
          end
        end
        # END HAS_MANY
      else
        # Nice n simple straight assignment to a column variable
        #puts "INFO: LOADER BASE processing #{method_detail.name}"
        @current_method_detail.assign(@load_object, @current_value)
      end
    end
    
    def failure
      @failed_objects << @load_object unless( !load_object.new_record? || @failed_objects.include?(@load_object))
    end

    def save
      #puts "DEBUG: SAVING #{load_object.class} : #{load_object.inspect}" #if(options[:verbose])
      begin
        result = @load_object.save
        
        @loaded_objects << @load_object unless(@loaded_objects.include?(@load_object))

        return result
      rescue => e
        failure
        puts "Error saving #{@load_object.class} : #{e.inspect}"
        logger.error e.backtrace
        raise "Error in save whilst processing column #{@current_method_detail.name}" if(@options[:strict])
      end
    end

    def self.default_object_for( klass )
      @default_data_objects ||= {}
      @default_data_objects[klass]
    end
    
    def set_default_value( name, value )
      @default_values[name] = value
    end

    def set_override_value( operator, value )
      @override_values[operator] = value
    end
    
    def default_value(name)
      @default_values[name]
    end
    
    def override_value( operator )
      @current_value = @override_values[operator] if(@override_values[operator])
    end
    
    
    def set_prefix( name, value )
      @prefixes[name] = value
    end

    def prefixes(name)
      @prefixes[name]
    end

    def set_postfix( name, value )
      @postfixes[name] = value
    end

    def postfixes(name)
      @postfixes[name]
    end
    
    
    # Reset the loader, including database object to be populated, and load counts
    #
    def reset(object = nil)
      @load_object = object || new_load_object
      @loaded_objects, @failed_objects = [],[]
      @current_value = nil
    end

    
    def new_load_object
      @load_object = @load_object_class.new
      @load_object
    end

    def abort_on_failure?
      @options[:abort_on_failure] == 'true'
    end

    def loaded_count
      @loaded_objects.size
    end

    def failed_count
      @failed_objects.size
    end


    # Check whether headers contains supplied list
    def headers_contain_mandatory?( mandatory_list )
      [ [*mandatory_list] - @headers].flatten.empty?
    end


    # Check whether headers contains supplied list
    def missing_mandatory_headers( mandatory_list )
      [ [*mandatory_list] - @headers].flatten
    end
    
    def find_or_new( klass, condition_hash = {} )
      @records[klass] = klass.find(:all, :conditions => condition_hash)
      if @records[klass].any?
        return @records[klass].first
      else
        return klass.new
      end
    end

    private

    def save_if_new
      #puts "SAVE", load_object.inspect
      save if(load_object.valid? && load_object.new_record?)
    end
  
  end

end