class NetzkeFieldList < ActiveRecord::Base
  belongs_to :user
  belongs_to :role
  belongs_to :parent, :class_name => "NetzkeFieldList"
  has_many :children, :class_name => "NetzkeFieldList", :foreign_key => "parent_id"


  # If the <tt>model</tt> param is provided, then this preference will be assigned a parent preference
  # that configures the attributes for that model. This way we can track all preferences related to a model.
  def self.write_list(name, list, model = nil)
    pref_to_store_the_list = self.pref_to_write(name)
    pref_to_store_the_list.try(:update_attribute, :value, list.to_json)
    
    # link this preference to the parent that contains default attributes for the same model
    if model
      model_level_attrs_pref = self.pref_to_read("#{model.tableize}_model_attrs")
      model_level_attrs_pref.children << pref_to_store_the_list if model_level_attrs_pref && pref_to_store_the_list
    end
  end
  
  def self.read_list(name)
    json_encoded_value = self.pref_to_read(name).try(:value)
    ActiveSupport::JSON.decode(json_encoded_value) if json_encoded_value
  end

  # Read model-level attrs
  def self.read_attrs_for_model(model)
    read_list("#{model.tableize}_model_attrs")
  end
  
  # Write model-level attrs
  def self.write_attrs_for_model(model, data)
    write_list("#{model.tableize}_model_attrs", data)
  end
  
  # Options:
  # :attr - attribute to propagate. If not specified, all attrs found in configuration for the model
  # will be propagated.
  def self.update_children_on_attr(model, options = {})
    attr_name = options[:attr].try(:to_s)
    
    parent_pref = pref_to_read("#{model.tableize}_model_attrs")
    
    if parent_pref
      parent_list = ActiveSupport::JSON.decode(parent_pref.value)
      # Rails.logger.debug "!!! parent_list: #{parent_list.inspect}\n"
      parent_pref.children.each do |ch|
        child_list = ActiveSupport::JSON.decode(ch.value)
        # Rails.logger.debug "!!! child_list: #{child_list.inspect}\n"
        
        if attr_name
          # propagate a certain attribute
          propagate_attr(attr_name, parent_list, child_list)
        else
          # propagate all attributes found in parent
          all_attrs = parent_list.first.try(:keys)
          all_attrs && all_attrs.each{ |attr_name| propagate_attr(attr_name, parent_list, child_list) }
        end
        
        ch.update_attribute(:value, child_list.to_json)
      end
    end
  end
  
  # meta_attrs:
  #   {"city"=>{"included"=>true}, "building_number"=>{"default_value"=>100}}
  def self.update_children(model, meta_attrs)
    parent_pref = pref_to_read("#{model.tableize}_model_attrs")


    if parent_pref
      parent_pref.children.each do |ch|
        child_list = ActiveSupport::JSON.decode(ch.value)
        
        meta_attrs.each_pair do |k,v|
          child_list.detect{ |child_attr| child_attr["name"] == k }.try(:merge!, v)
        end
        
        ch.update_attribute(:value, child_list.to_json)
      end
    end
  end

  private
  
    def self.propagate_attr(attr_name, src_list, dest_list)
      for src_field in src_list
        dest_field = dest_list.detect{ |df| df["name"] == src_field["name"] }
        dest_field[attr_name] = src_field[attr_name] if dest_field && src_field[attr_name]
      end
    end
  
    # Overwrite pref_to_read, pref_to_write methods, and find_all_for_widget if you want a different way of 
    # identifying the proper preference based on your own authorization strategy.
    #
    # The default strategy is:
    #   1) if no masq_user or masq_role defined
    #     pref_to_read will search for the preference for user first, then for user's role
    #     pref_to_write will always find or create a preference for the current user (never for its role)
    #   2) if masq_user or masq_role is defined
    #     pref_to_read and pref_to_write will always take the masquerade into account, e.g. reads/writes will go to
    #     the user/role specified
    #   
    def self.pref_to_read(name)
      name = name.to_s
      session = Netzke::Base.session
      cond = {:name => name}
    
      if session[:masq_user]
        # first, get the prefs for this user it they exist
        res = self.find(:first, :conditions => cond.merge({:user_id => session[:masq_user]}))
        # if it doesn't exist, get them for the user's role
        user = User.find(session[:masq_user])
        res ||= self.find(:first, :conditions => cond.merge({:role_id => user.role.id}))
        # if it doesn't exist either, get them for the World (role_id = 0)
        res ||= self.find(:first, :conditions => cond.merge({:role_id => 0}))
      elsif session[:masq_role]
        # first, get the prefs for this role
        res = self.find(:first, :conditions => cond.merge({:role_id => session[:masq_role]}))
        # if it doesn't exist, get them for the World (role_id = 0)
        res ||= self.find(:first, :conditions => cond.merge({:role_id => 0}))
      elsif session[:netzke_user_id]
        user = User.find(session[:netzke_user_id])
        # first, get the prefs for this user
        res = self.find(:first, :conditions => cond.merge({:user_id => user.id}))
        # if it doesn't exist, get them for the user's role
        res ||= self.find(:first, :conditions => cond.merge({:role_id => user.role.id}))
        # if it doesn't exist either, get them for the World (role_id = 0)
        res ||= self.find(:first, :conditions => cond.merge({:role_id => 0}))
      else
        res = self.find(:first, :conditions => cond)
      end
    
      res      
    end
  
    def self.pref_to_write(name)
      name = name.to_s
      session = Netzke::Base.session
      cond = {:name => name}
    
      if session[:masq_user]
        cond.merge!({:user_id => session[:masq_user]})
        # first, try to find the preference for masq_user
        res = self.find(:first, :conditions => cond)
        # if it doesn't exist, create it
        res ||= self.new(cond)
      elsif session[:masq_role]
        # first, delete all the corresponding preferences for the users that have this role
        Role.find(session[:masq_role]).users.each do |u|
          self.delete_all(cond.merge({:user_id => u.id}))
        end
        cond.merge!({:role_id => session[:masq_role]})
        res = self.find(:first, :conditions => cond)
        res ||= self.new(cond)
      elsif session[:masq_world]
        # first, delete all the corresponding preferences for all users and roles
        self.delete_all(cond)
        # then, create the new preference for the World (role_id = 0)
        res = self.new(cond.merge(:role_id => 0))
      elsif session[:netzke_user_id]
        res = self.find(:first, :conditions => cond.merge({:user_id => session[:netzke_user_id]}))
        res ||= self.new(cond.merge({:user_id => session[:netzke_user_id]}))
      else
        res = self.find(:first, :conditions => cond)
        res ||= self.new(cond)
      end
      res
    end
end
