require 'rubygems'
require 'activerecord'
require 'active_record/connection_adapters/abstract_adapter'
require 'sds-rest'
require 'uuidtools'

module ActiveRecord
  class Base
    def self.SDS_connection(config)
      require_library_or_gem 'sds-rest' unless self.class.const_defined?(:SDSRest)
      
      config = config.symbolize_keys

      username    = config[:username] ? config[:username].to_s : ''
      password    = config[:password] ? config[:password].to_s : ''
      
      conn      = SDSRest::Service.new
      ConnectionAdapters::SDSAdapter.new(conn, logger)
    end
  
  end

    module ConnectionAdapters

      class SDSAdapter < AbstractAdapter

      def initialize(conn, logger=nil)
        super(conn, logger)

        #check to see if our table container exists
        container = @connection.get_container 'data'

        if(container.is_a?(Net::HTTPNotFound))
          container = @connection.create_container 'data'
        end
      end

      def tables
        []
      end

      def adapter_name
        'SDS'
      end

      def supports_migrations?
        true
      end

      def columns(table_name, name=nil)
        log(table_name, name)
        entity = @connection.get_entity 'schema', table_name
        entity = REXML::Document.new(entity.body)
        columns = []

        entity.root().elements.each { |element| 
           columns << Column.new(element.name, nil, element.text)
          }


        columns      
      end

      def select_all(sql, name = nil)
        select(sql, name)
      end

      def select_one(sql, name = nil)
        result = select_all(sql, name)
        result.first if result
      end

      # Returns a single value from a record
      def select_value(sql, name = nil)
        if result = select_one(sql, name)
          result.values.first
        end
      end

      # Returns an array of the values of the first column in a select:
      #   select_values("SELECT id FROM companies LIMIT 3") => [1,2,3]
      def select_values(sql, name = nil)
        raise NotImplementedError, "select_values is not implemented"
      end

      # Returns an array of arrays containing the field values.
      # Order is the same as that returned by #columns.
      def select_rows(sql, name = nil)
        raise NotImplementedError, "select_rows is not implemented"
      end

      # Executes the SQL statement in the context of this connection.
      def execute(sql, name = nil)
        raise NotImplementedError, "execute is not implemented"
      end

      def delete(sql, name= nil)
        log(sql, name)

        #remove any new lines
        sql.delete!("\n")

        #parse out the ID
        sql =~ /WHERE\s*ID\s*=\s*'(.*)'/i
        id = $1

        @connection.delete_entity 'data', id
        1
      end

      def quote_string(string) 
        string.gsub!(",", "&#44;")
        super
      end

      def insert(sql, name = nil, pk = nil, id_value = nil, sequence_name = nil)
        log(sql, name)
        vals = parse_insert_sql(sql)
        columns = vals[2].delete('(').delete(')').split(",")
        values = vals[3].delete("(").delete(")").split(",")

        columns.each { |val| val.strip! }
        values.each { |val| val.strip! ;val.delete!("'") }

        hash = Hash[*columns.zip(values).flatten]
        
        entityid = id_value
        
        if(entityid.nil?)
        
          entityid = hash['id'] || hash['Id']
          
          if(entityid == 'NULL')
            entityid = rand(999999)       
          end
        end
        
        hash['Id'] = entityid.to_s
        hash['id'] = entityid.to_s

        @connection.create_entity 'data', vals[1].to_s, entityid, hash
        entityid.to_s
      end

      def update(sql, name= nil)
        log(sql, name)

        sql.delete!("\n")
        puts sql

        sql =~ /SET\s*(.*)\s*WHERE/i
        
        if($1.nil?)
        sql =~ /SET\s*(.*)/i  
        end
              
        updates = $1.strip
        
        sql =~ /WHERE\s*ID\s*=\s*'(.*)'/i
        id = $1
              
        sql =~ /UPDATE\s*(.*)\s*SET/i
        table = $1
        
        entities = nil

        if(!id.nil?)          
          entities = select('select * from ' + table + ' where ' + table.strip! + '.Id = "' + id + '"', "select")    #get_entities_from_response(@connection.get_entity('data', id), nil)
          puts entities
        else
          entities = select('select * from ' + table + ' ', "select")
        end
          
        colupdates = nil

        entities.each{ |entity| 
          
          #if there is no AND then we have just one column getting updated
          if(updates.index(/, /i).nil?)
            updates =~ /(.*) = (.*)/i
            entity[$1.to_s] = $2.to_s.delete("'")        
          else
            colupdates = updates.split(", ")
            colupdates.each { |update|
              update =~ /(.*) = (.*)/i
              entity[$1.to_s] = $2.to_s.delete("'")
            }
          end
        
          entityid = entity['id'] || entity["Id"]
                    
          @connection.update_entity 'data', table, entityid, nil, entity
        }
      
        colupdates || updates
      end

        

           def initialize_schema_information
              begin
                @connection.create_entity 'schema', 'table', quote_table_name(ActiveRecord::Migrator.schema_info_table_name), :version => :string
                @connection.create_entity 'data', quote_table_name(ActiveRecord::Migrator.schema_info_table_name), 'schema_info1', :version => 0
                @connection.create_entity 'data', 'sequence', 0, :sequence => 1
              rescue ActiveRecord::StatementInvalid
                # Schema has been initialized
              end
            end

      def select(sql, name = nil)

        log(sql, name)
        sql =~/select (.*) from (\w*)\s*/i
        
        columns = $1
        
        if(columns == "*")
          columns = nil
        end
          
        if(!columns.nil?)
          if(columns.include?(","))
            columns = columns.split(",")
          else
            columns = [columns]
          end        
        end
        
        entityname = $2

        sql =~/select .* from (\w*)\s*where (.*)/i
        where = $2
                
        query = ""
        #where clause
        if(!where.nil?)
          #and the AND
          query << " %26%26 " 
          
          #remove any order or limits for now - possible future feature
          where.gsub!(/LIMIT .*/, "")
          where.gsub!(/ORDER BY .*/, "")

          #need double equals, switch not equal
          where.gsub!("=","==")
          where.gsub!("<>","!=")
          #no IS, just ==
          where.gsub!("IS NULL", '== "NULL"')
          where.gsub!("!= NULL", '!= "NULL"')
          #if there is no AND and an ID tag add it as is
          if(where.index(/ AND /i).nil? && (!where.index('.Id').nil? || !where.index('.id').nil?))

            query << where

            #has to be .Id for metadata
            query.gsub!(".id",".Id")
            #quote all values
            query.gsub!(/== (.*)\)/,'== "\1"')

          else

          #add the where clause
          query << where
          
          #remove any entity qualifiers (will add them back soon)
          query.gsub!(entityname + ".", "")
          
          #replace AND
          query.gsub!(/AND/i, "%26%26 ")

          #add double-quotes
          query.gsub!(/== '([^']*)'/, '== "\1"')
          
          #add entity qualifier and format
          query.gsub!(/ ([^\s]*) ==/, " " + entityname + '["\1"] ==')
          
          #quote numbers
          query.gsub!(/== ([0-9]+)/, '== "\1"')
          puts query
          #quote numbers
          query.gsub!(/!= \'+([0-9]+)\'+/, '!= "\1"')
          
          
          #replace OR
          query.gsub!(/ OR /i," || ")
          
          #replace id with ID
          query.gsub!(" id ", entityname + ".Id ")
          end
        end

        #remove features we don't support
        query.delete!("(")
        query.delete!(")")
        query.delete!("'")

        query =  'from ' + entityname + ' in entities where ' + entityname + '.Kind == "' + entityname + '" ' + query.strip + " select " + entityname
        log(query, 'query')
        puts query
        response = @connection.query('data', query)
        get_entities_from_response(response, columns)      
      end



      def create_table(name, options=nil)
        table_definition = TableDefinition.new(self)
        if(!options.nil?)
          table_definition.primary_key(options[:primary_key] || "id") unless options[:id] == false
        end
        yield table_definition

        columns = build_column_hash(table_definition)

        #check to see if our table container exists
        container = @connection.get_container 'schema'

        if(container.is_a?(Net::HTTPNotFound))
          container = @connection.create_container 'schema'
        end

        @connection.create_entity 'schema', 'table', name, columns
        log('created table: ' + name, 'MIGRATION')
      end

      def add_column(table_name, column_name, type, options = {})

        entity = @connection.get_entity 'schema', table_name
        entity = REXML::Document.new(entity.body)

        options = {}      
        entity.root().elements.each { |element2|       
          options[element2.name] = element2.text
        }

        options[column_name] = type      

        @connection.update_entity 'schema', 'table', table_name, nil, options
      end

      def rename_column(table_name, column_name, new_column_name)
          entity = @connection.get_entity 'schema', table_name
          entity = REXML::Document.new(entity.body)

          options = {}      
          entity.root().elements.each { |element2|       

            if(element2.name == column_name.to_s)
              options[new_column_name.to_s] = element2.text
            else
              options[element2.name] = element2.text
            end
          }    
          @connection.delete_entity 'schema', table_name
          @connection.create_entity 'schema', 'table', table_name, options 
      end

      def remove_column(table_name, column_name)
        entity = @connection.get_entity 'schema', table_name
        entity = REXML::Document.new(entity.body)

        options = {}      
        entity.root().elements.each { |element2|       

          if(element2.name != column_name)
            options[element2.name] = element2.text
          end
        }    

        @connection.delete_entity 'schema', table_name
        @connection.create_entity 'schema', 'table', table_name, options
      end

      def build_column_hash(table)
        columnhash = {}

        table.columns.each { |column| 
          columnhash[column.name] = column.type
        }

        columnhash
      end

      def parse_insert_sql(sql)
        sql =~ /(insert\s*into\s*)([^\s]*)\s*(\([^\)]*\))\s*values\s*(\([^\)]*\))/i
        [$1,$2,$3,$4]
      end

      def get_entities_from_response(response, columns=nil)
        
        entity = REXML::Document.new(response.body)
        entities = []
        entity.root().elements.each { |element| 
          
          options = {}      
          element.elements.each { |element2|       
            if(columns.nil? || columns.include?(element2.name))  
              if(element2.text == "NULL")
                options[element2.name] = nil
              else
              options[element2.name] = element2.text
              end
            end
          }
          entities.push(options)
          }
        puts entities

        #if this is a count then just add the count of entities as the only column
        if(!columns.nil? && columns.first == 'count(*) AS count_all')
          [{'count_all', entities.length}]
        else
          entities
        end
      end

      def get_entity_from_response(response)
        get_entities_from_response(response)[0]
      end

      end
    end
  end