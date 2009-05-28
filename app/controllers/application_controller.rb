# Filters added to this controller apply to all controllers in the application.
# Likewise, all the methods added will be available for all controllers.

class ApplicationController < ActionController::Base

  include AuthenticatedSystem
  include ExceptionNotifiable

  require_dependency "activity.rb"
  require_dependency "blast.rb" 
  require_dependency "relationship.rb"   
  require_dependency "capital.rb"
   
  rescue_from ActionController::InvalidAuthenticityToken, :with => :bad_token
  rescue_from Facebooker::Session::SessionExpired, :with => :fb_session_expired 

  helper :all # include all helpers, all the time
  
  # Make these methods visible to views as well
  helper_method :facebook_session, :government_cache, :current_partner, :current_user_endorsements, :current_priority_ids, :current_following_ids, :current_ignoring_ids, :current_following_facebook_uids, :current_government, :facebook_session, :is_robot?, :is_misc?, :remit, :js_help
  
  # switch to the right database for this government
  before_filter :hijack_db, :unless => :is_misc?
  before_filter :check_subdomain, :unless => :is_misc?
  
  before_filter :set_facebook_session, :unless => [:is_robot?, :is_misc?]
  before_filter :load_actions_to_publish, :unless => [:is_robot?, :is_misc?]
  before_filter :check_facebook, :unless => [:is_robot?, :is_misc?]
    
  before_filter :check_blast_click, :unless => [:is_robot?, :is_misc?]
  before_filter :check_priority, :unless => [:is_robot?, :is_misc?]
  before_filter :check_referral, :unless => [:is_robot?, :is_misc?]
  before_filter :check_suspension, :unless => [:is_robot?, :is_misc?]
  before_filter :update_loggedin_at, :unless => [:is_robot?, :is_misc?]

  site :get_site
  layout :get_site

  # See ActionController::RequestForgeryProtection for details
  # Uncomment the :secret if you're not using the cookie session store
  protect_from_forgery #:secret => 'd0451bc51967070c0872c2865d2651e1'

  protected
  
  def get_site
    return current_government.layout if not is_robot? and not is_misc?
  end

  # manually establish a connection to the database for this government, and if it doesn't exist, redirect to nationbuilder.com
  # it won't switch databases if it's in single government mode
  def hijack_db
    unless current_government
      redirect_to "http://" + NB_CONFIG['multiple_government_base_url'] + "/"
      return
    end
    current_government.switch_db
  end  
  
  def current_government
    return @current_government if @current_government
    if NB_CONFIG['multiple_government_mode'] # we're in multiple government mode, so gotta figure out what govt this is based on the domain
      found = request.host
      unless @current_government = Rails.cache.read('government-' + request.host)
        if request.host.include?(NB_CONFIG['multiple_government_base_url']) and request.subdomains.size > 0
          @current_government = Government.find_by_short_name(request.subdomains.last)
        end
        if not @current_government and request.subdomains.size > 0 
          try_domain = request.host.split('.')[1..request.host.split('.').size-1].join('.')
          @current_government = Rails.cache.read('government-' + try_domain)
          found = try_domain
        end
        unless @current_government
          @current_government = Government.find_by_domain_name(request.host)
          found = request.host
          if not @current_government and request.subdomains.size > 0 
            @current_government = Government.find_by_domain_name(try_domain)
            found = try_domain
          end
        end
        if @current_government
          @current_government.update_counts
          # note that it writes the config to cache INCLUDING the subdomain, even if the subdomain is a partner of the parent government.
          # this is so we don't miss the memcache hit the next time
          Rails.cache.write('government-' + found,@current_government, :expires_in => 15.minutes)
        end        
      end
    else # single government mode
      @current_government = Rails.cache.read('government')
      if not @current_government
        @current_government = Government.last
        @current_government.update_counts
        Rails.cache.write('government', @current_government, :expires_in => 15.minutes) 
      end
    end
    return @current_government
  end
  
  # Will either fetch the current partner or return nil if there's no subdomain
  def current_partner
    return nil if request.subdomains.size == 0 or request.host == current_government.base_url or request.subdomains.first == 'dev' or (request.host.include?(NB_CONFIG['multiple_government_base_url']) and request.subdomains.size == 1)
    @current_partner ||= Partner.find_by_short_name(request.subdomains.first)
  end
  
  def current_user_endorsements
		@current_user_endorsements ||= current_user.endorsements.active.by_position.paginate(:include => :priority, :page => session[:endorsement_page], :per_page => 25)
  end
  
  def current_priority_ids
    return [] unless logged_in? and current_user.endorsements_count > 0
    @current_priority_ids ||= current_user.endorsements.active_and_inactive.collect{|e|e.priority_id}
  end  
  
  def current_following_ids
    return [] unless logged_in? and current_user.followings_count > 0
    @current_following_ids ||= current_user.followings.up.collect{|f|f.other_user_id}
  end
  
  def current_following_facebook_uids
    return [] unless logged_in? and current_user.followings_count > 0 and current_user.has_facebook?
    @current_following_facebook_uids ||= current_user.followings.up.collect{|f|f.other_user.facebook_uid}.compact
  end  
  
  def current_ignoring_ids
    return [] unless logged_in? and current_user.ignorings_count > 0
    @current_ignoring_ids ||= current_user.followings.down.collect{|f|f.other_user_id}    
  end

  def remit
    @remit ||= begin
      sandbox = !Rails.env.production?
      Remit::API.new(FPS_ACCESS_KEY, FPS_SECRET_KEY, sandbox)
    end
  end
  
  def load_actions_to_publish
    @user_action_to_publish = flash[:user_action_to_publish] 
    flash[:user_action_to_publish]=nil
  end  
  
  def check_suspension
    if logged_in? and current_user and current_user.status == 'suspended'
      self.current_user.forget_me if logged_in?
      cookies.delete :auth_token
      reset_session
      flash[:notice] = "This account has been suspended."
      redirect_back_or_default('/')
      return  
    end
  end
  
  # they were trying to endorse a priority, so let's go ahead and add it and take htem to their priorities page immediately    
  def check_priority
    return unless logged_in? and session[:priority_id]
    @priority = Priority.find(session[:priority_id])
    @value = session[:value].to_i
    if @priority
      if @value == 1
        @priority.endorse(current_user,request,current_partner,@referral)
      else
        @priority.oppose(current_user,request,current_partner,@referral)
      end
    end  
    session[:priority_id] = nil
    session[:value] = nil
  end
  
  def update_loggedin_at
    return unless logged_in?
    return unless current_user.loggedin_at.nil? or Time.now > current_user.loggedin_at+30.minutes
    User.find(current_user.id).update_attribute(:loggedin_at,Time.now)
  end

  def check_blast_click
    # if they've got a ?b= code, log them in as that user
    if params[:b] and params[:b].length > 2
      @blast = Blast.find_by_code(params[:b])
      if @blast and not logged_in?
        self.current_user = @blast.user
        @blast.increment!(:clicks_count)
      end
      redirect = request.path_info.split('?').first
      redirect = "/" if not redirect
      redirect_to redirect
      return
    end
  end

  def check_subdomain
    if not current_partner and RAILS_ENV == 'production' and request.subdomains.any? and request.subdomains.first != 'dev' and not (request.host.include?(NB_CONFIG['multiple_government_base_url']) and request.subdomains.size == 1)
      redirect_to 'http://' + current_government.base_url + request.path_info
      return
    end    
  end
  
  def check_referral
    if not params[:referral_id].blank?
      @referral = User.find(params[:referral_id])
    else
      @referral = nil
    end    
  end  
  
  # if they're logged in with a wh2 account, AND connected with facebook, but don't have their facebook uid added to their account yet
  def check_facebook 
    return unless Facebooker.api_key
    if logged_in? and facebook_session and not current_user.has_facebook?
      return if facebook_session.user.uid == 55714215 and current_user.id != 1 # this is jim, don't add his facebook to everyone's account!
      @user = User.find(current_user.id)
      if not @user.update_with_facebook(facebook_session)
        return
      end
      if not @user.activated?
        @user.activate!
      end      
      @current_user = User.find(current_user.id)
      flash.now[:notice] = t('facebook.synced', :government_name => current_government.name)
    end      
  end
  
  def is_robot?
    return true if request.format == 'rss' or params[:controller] == 'pictures'
    request.user_agent =~ /\b(Baidu|Gigabot|Googlebot|libwww-perl|lwp-trivial|msnbot|SiteUptime|Slurp|WordPress|ZIBB|ZyBorg)\b/i
  end
  
  def is_misc?
    request.host[0..4] == 'misc.'
  end
  
  def bad_token
    flash[:error] = t('application.bad_token')
    respond_to do |format|
      format.html { redirect_to request.referrer||'/' }
      format.js { 
        render :update do |page|
           page.redirect_to request.referrer||'/'
        end
      }
    end
  end
  
  def fb_session_expired
    self.current_user.forget_me if logged_in?
    cookies.delete :auth_token
    reset_session    
    flash[:error] = t('application.fb_session_expired')
    respond_to do |format|
      format.html { redirect_to request.referrer||'/' }
      format.js { 
        render :update do |page|
           page.redirect_to request.referrer||'/'
        end
      }
    end    
  end
  
  def js_help
    JavaScriptHelper.instance
  end

  class JavaScriptHelper
    include Singleton
    include ActionView::Helpers::JavaScriptHelper
  end  
  
end

module ThinkingSphinx
  class Search
    class << self
      
      def search_results(*args)
        options = args.extract_options!
        query   = args.join(' ')
        client  = client_from_options options
  
        query = star_query(query, options[:star]) if options[:star]
  
        extra_query, filters = search_conditions(
          options[:class], options[:conditions] || {}
        )
        client.filters   += filters
        client.match_mode = :extended unless extra_query.empty?
        query             = [query, extra_query].join(' ')
        query.strip!  # Because "" and " " are not equivalent
          
        set_sort_options! client, options
  
        client.limit  = options[:per_page].to_i if options[:per_page]
        page          = options[:page] ? options[:page].to_i : 1
        page          = 1 if page <= 0
        client.offset = (page - 1) * client.limit

        # changing the index to search based on the current government
        new_index = Government.current.short_name + "_" + options[:class].to_s.tableize.singularize
        begin
          ::ActiveRecord::Base.logger.debug "Sphinx: #{query} Index: #{new_index}"
          # hijacking the index to search
          if NB_CONFIG["multiple_government_mode"]
            results = client.query query, new_index
          else
            results = client.query query
          end
          ::ActiveRecord::Base.logger.debug "Sphinx Result: #{results[:matches].collect{|m| m[:attributes]["sphinx_internal_id"]}.inspect}"
        rescue Errno::ECONNREFUSED => err
          raise ThinkingSphinx::ConnectionError, "Connection to Sphinx Daemon (searchd) failed."
        end
  
        return results, client
      end
    end
  end
end