#
# Copyright (c) 2006-2009 National ICT Australia (NICTA), Australia
#
# Copyright (c) 2004-2009 WINLAB, Rutgers University, USA
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
#
# = appDefinition.rb
#
# == Description
#
# This file defines the AppDefinition class
#
#

require 'omf-common/syncVariables.rb'
require "omf-expctl/experiment.rb"
require "omf-expctl/handlerCommands.rb"
require "omf-expctl/application/appVersion.rb"
require "omf-expctl/oml/oml_mpoint.rb"
require "rexml/document"

#
# Define a new application. The supplied block is
# executed with the new AppDefinition instance
# as a single argument.
#
# - uri =  the URI identifying this new application
# - name = the name of this new application
# - block =  the block to execute
#
def defApplication(uri, name = nil, &block)
  p = AppDefinition.create(uri)
  p.name = name
  block.call(p) if block
end

#
# This class describes an application which can be used
# for an experiment using OMF
#
class AppDefinition < MObject

  @@apps = Hash.new

  #
  # Return a known AppDefinition instance.
  #
  # - uri = URI identifying the AppDefinition
  #
  # [Return] an AppDefinition object
  #
  def self.[](uri)
    app = @@apps[uri]
    if app == nil
      MObject.debug('AppDefinition: ', 'Loading app definition "', uri, '".')
      str, type = OConfig.load(uri, true)
      #MObject.debug('Prototype: ', 'str: "', str, '".')
      if type == "text/xml"
        #app = AppDefinition.from_xml(str.to_xml???)
      elsif type == "text/ruby"
        #eval(str)  # this should create the desired app definition
        app = @@apps[uri]
      end
      if app == nil
        raise "Unknown AppDefinition '" + uri + "'."
      end
    end
    return app
  end

  #
  # Return a new instance.
  #
  # - uri = the URI identifying this new AppDefinition
  #
  # [Return] an AppDefinition object
  #
  def self.create(uri)
    if @@apps.key?(uri)
      raise "Duplicate definition of application '#{uri}'"
    end
    return self.new(uri)
  end

  #
  # Unmarshall an AppDefinition instance from an XML tree.
  #
  # appDefRoot = root of the XML tree holding the application definition
  #
  # [Return] an AppDefinition object
  #
  def self.from_xml(appDefRoot)
    if (appDefRoot.name != "application")
      raise "Application definition needs to start with an 'application' element"
    end
    id = appDefRoot.attributes['id']
    if @@apps[id] != nil
      raise "Application definition '#{id}' already loaded."
    end
    a = AppDefinition.create(id)
    a.from_xml(appDefRoot)
    return a
  end
  
  #
  # Forget all app definitions. This does not remove any applications already
  # instantiated using exisiting app definitions. This is primarily used by
  # the test harness
  #
  def self.reset()
    @@apps = {}
  end

  # Local id
  attr_reader :id

  # location of the XML serialization of this definition
  attr_reader :uri

  # Name of AppDefinition
  attr_accessor :name

  # Version of AppDefinition
  attr_reader :version

  # Copyright notice (can be a URI)
  attr_reader :copyright

  # Short and longer description of the AppDefinition
  attr_accessor :shortDescription, :description

  # Properties of the AppDefinition itself
  attr_reader :properties

  # Properties of the AppDefinition itself
  attr_reader :measurements

  # Location of binary install package
  attr_accessor :appPackage

  # Location of development/source install package
  attr_reader :developmentRepository

  # Name to use for apt-get install (nil if packet is not in apt)
  attr_accessor :debPackage

  # Name to use for rpm install (nil if packet is not in rpm)
  attr_accessor :rpmPackage

  # Location of binary on installed machine
  attr_accessor :path

  # Environment settings required for running this application
  attr_accessor :environment
  
  # Prefix used for creating OML table names
  attr_accessor :omlPrefix
  
  protected :initialize

  #
  # Create a new AppDefinition
  #
  def initialize(uri)
    @@apps[uri] = self

    @id = uri
    @uri = uri
    @properties = Hash.new
    @measurements = Hash.new
    @environment = Hash.new
    @instCounter = SynchronizedInteger.new
  end
  
  #
  # Instruct this AppDefinition that another instance
  # of this application has been instantiated
  #
  #  [Return] the number of application instance created from this AppDefinition
  #
  def addInstance()
    return @instCounter.incr()
  end

  #
  # Return an array containing the command line arguments, which are required
  # to start this type of application. The bindings for these arguments are
  # defined in 'bindings'. 
  #
  # - bindings = Bindings for the command line arguments
  # - appID = Name of the application
  # - nodeSet =  Name of the group of resources that will execute this app
  #
  # [Return] the complete resulting array of command line arguments
  #
  def getCommandLineArgs(bindings, appId, nodeSet)

    cmd = []
    # First sort the properties according to their order 
    # (if specified in their options Hash)
    sortedProperties = @properties.sort {|a,b| a[1] <=> b[1]}
    sortedProperties.each {|a|
      name = a[0]
      prop = a[1]
      type = prop.type
      if ((value = bindings[name]) != nil)
        # This Property is a Dynamic Experiment Property...
        if value.kind_of?(ExperimentProperty)
          value.onChange { |v|
            nodeSet.send(ECCommunicator.instance.create_message(
                                        :cmdtype => :STDIN,
                                        :appID => appId,
                                        :value => "#{prop.name} #{v}"))
          }
          if (value = value.value) == nil
            next # continue with the next property
          end
        end
        # This Property is a Static Initialization Property 
        # First, check if it has the correct type
        case type
        when :integer, :int
          if !value.kind_of?(Integer)
            raise "Wrong type '#{value}' for Property '#{name}' "+
                  "(expecting Integer)"
          end
        when :string
          if !value.kind_of?(String) #&& !value.kind_of?(Node)
            raise "Wrong type '#{value}' for Property '#{name}' "+
                  "(expecting String)"
          end
        when :boolean
          if ((value != false) && (value != true)) 
            raise "Wrong type '#{value}' for Property '#{name}' "+
                  "(expecting Boolean)"
          end
        when nil
        when ExperimentProperty
          #do nothing...
        else
          raise "Unknown type '#{type}' for Property '#{name}'" 
        end
        # Second, add the corresponding flag+value to command line, if required
        if (((type == :boolean) && (value == true)) || (type != :boolean))
          acmd = [prop.parameter]
          if ((type != :boolean) && (value != nil))
            acmd << value
          end
          cmd << acmd
        end
      end
    }
    return cmd
  end

  #
  # Return the AppDefinition definition as XML element
  #
  # [Return] an XML element (REXML::Element object)
  #
  def to_xml()
    a = REXML::Element.new("application")
    a.add_attribute("id", id)
    a.add_element("name", id).text = name != nil ? name : id
    if (uri != nil)
      a.add_element("uri").text = uri
    end

    if (version != nil)
      a.add_element(version.to_xml)
    end
    a.add_element("copyright").text = copyright
    a.add_element("shortDescription").text = shortDescription
    a.add_element("description").text = description

    if @properties.length > 0
      pe = a.add_element("properties")
      @properties.each_value {|p|
        pe.add_element(p.to_xml)
      }
    end

    if @measurements.length > 0
      me = a.add_element("measurements")
      @measurements.each_value {|m|
        me.add_element(m.to_xml)
      }
    end

    a.add_element("path").text = @path
    if (@environment.length > 0)
      pv = a.add_element("environments")
      @environment.each {|k, v|
        pv.add_element('env', {'name' => k}).text = v
      }
    end
    return a
  end

  #
  # Initialize the object with information contained in
  # an XML tree rooted at "appRoot".
  #
  # DO NOT CALL DIRECTLY. Use the class method instead
  #
  # - appRoot = the XML element "application"
  #
  def from_xml(appRoot)
    # assumes we already checked that appRoot.name = 'application'
    # and extracted 'id'. See AppDefinition.from_xml.
    @name = appRoot.attributes['name']
    appRoot.elements.each { |el|
      case el.name
      when 'url' : @uri = el.text
      when 'name' : @name = el.text
      when Version::VERSION_EL_NAME :  # @version = Version.from_xml(el)
      when 'copyright' : @copyright = el.text;
      when 'shortDescription' : @shortDescription = el.text;
      when 'description' : @description = el.text;

      when 'properties'
        el.elements.each { |el|
          p = AppProperty.from_xml(el)
          @properties[p.name] = p
        }

      when 'measurements'
        el.elements.each { |el|
          m = AppMeasurement.from_xml(el)
          @measurements[m.id] = m
        }

      when 'path' : @path = el.text;
      else
        warn "Ignoring element '#{el.name}'"
      end
    }
  end

  #
  # Define a property for this application.
  #
  # - name = the name of the property
  # - description = some text describing this property
  # - options = a list of options associated with this property 
  #
  # Currently, the following options are defined:
  #
  #   :type => <type> -- Checks if property value is of 'type'.
  #                       If type is 'Boolean', only the name is used if 'true'
  #   :dynamic => true|false -- If true, property can be changed at run-time
  #   :order => int   -- Uses the int to order the properties when forming command line
  #
  def defProperty(name = :mandatory, description = nil, parameter = nil, options = {})
    raise OEDLMissingArgumentException.new(:defProperty, :name) if name == :mandatory
    if @properties[name] != nil
      raise "Property '" + name + "' already defined."
    end
    prop = AppProperty.new(name, description, parameter, options)
    @properties[name] = prop
  end

  #
  # Return the version number for this application
  #
  # [Return] an AppVersion object
  #
  def version(major = nil, minor = 0, revision = 0)
    if (major == nil)
      return @version
    end
    @version = AppVersion.new(major, minor, revision)
  end

  #
  # Add a measurement point to this application.
  #
  # - mp_id = identification of measurement point
  # - description = some text describing this measurement point 
  # - opts = options for the entire MP
  #    - :table_name - Name to use for the SQL table name - default is to concatinate appName and mp_id
  # - block = an optional block to execute with this measurement point
  #
  # [Return] the newly created measurement point.
  #
  def defMeasurement(id, description = nil, opts = {}, &block)
    m = ::OMF::EC::OML::MPoint.new(id, description, opts)
    block.call(m) if block
    @measurements[id] = m
    return m
  end

  #
  # Set the Binary and Development repository associated with this application
  #
  # - binary =  the binary repository for this application
  # - development =  the development repository for this application
  #
  def repository(binary, development = nil)
    @appPackage = binary
    @developmentRepository = development
  end

  #
  # _Deprecated_ - Use defMeasurement(...) instead
  #
  def addMeasurement(id, description, metrics)
    raise OEDLIllegalCommandException.new(:addMeasurement) 
  end

  #
  # _Deprecated_ - Use defProperty(...) instead
  #
  def addProperty(name, description, mnemonic, type, isDynamic = false)
    raise OEDLIllegalCommandException.new(:addProperty) 
  end

end
