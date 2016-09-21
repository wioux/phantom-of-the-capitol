class CongressMember < ActiveRecord::Base
  validates_presence_of :bioguide_id

  has_many :actions, :class_name => 'CongressMemberAction', :dependent => :destroy
  has_many :required_actions, -> (object) { where "required = true AND SUBSTRING(value, 1, 1) = '$'" }, :class_name => 'CongressMemberAction'
  has_many :fill_statuses, :class_name => 'FillStatus', :dependent => :destroy
  has_many :recent_fill_statuses, -> (object) { where("created_at > ?", object.updated_at) }, :class_name => 'FillStatus'
  #has_one :captcha_action, :class_name => 'CongressMemberAction', :condition => "value = '$CAPTCHA_SOLUTION'"

  serialize :success_criteria, LegacySerializer

  RECENT_FILL_IMAGE_BASE = 'https://img.shields.io/badge/'
  RECENT_FILL_IMAGE_EXT = '.svg'

  class FillFailure < StandardError
  end

  def self.bioguide bioguide_id
    find_by_bioguide_id bioguide_id
  end

  def self.with_existing_bioguide bioguide_id
    yield find_by_bioguide_id bioguide_id
  end

  def self.with_new_bioguide bioguide_id
    yield self.create :bioguide_id => bioguide_id
  end

  def self.with_new_or_existing_bioguide bioguide_id
    yield self.find_or_create_by bioguide_id: bioguide_id
  end

  def as_required_json o={}
    as_json({
      :only => [],
      :include => {:required_actions => CongressMemberAction::REQUIRED_JSON}
    }.merge o)
  end

  def fill_out_form f={}, ct = nil, &block
    status_fields = {congress_member: self, status: "success", extra: {}}.merge(ct.nil? ? {} : {campaign_tag: ct})
    begin
      begin
        if REQUIRES_WATIR.include? self.bioguide_id
          success_hash = fill_out_form_with_watir f, &block
        elsif REQUIRES_WEBKIT.include? self.bioguide_id
          success_hash = fill_out_form_with_webkit f, &block
        else
          success_hash = fill_out_form_with_poltergeist f, &block
        end
      rescue Exception => e
        status_fields[:status] = "error"
        message = YAML.load(e.message)
        status_fields[:extra][:screenshot] = message[:screenshot] if message.is_a?(Hash) and message.include? :screenshot
        raise e, message[:message] if message.is_a?(Hash)
        raise e, message
      end

      unless success_hash[:success]
        status_fields[:status] = "failure"
        status_fields[:extra][:screenshot] = success_hash[:screenshot] if success_hash.include? :screenshot
        raise FillFailure, "Filling out the remote form was not successful"
      end
    rescue Exception => e
      # we need to add the job manually, since DJ doesn't handle yield blocks
      unless ENV['SKIP_DELAY']
        self.delay(queue: "error_or_failure").fill_out_form f, ct
        last_job = Delayed::Job.last
        last_job.attempts = 1
        last_job.run_at = Time.now
        last_job.last_error = e.message + "\n" + e.backtrace.inspect
        last_job.save
      end
      raise e
    ensure
      if RECORD_FILL_STATUSES
        fs = FillStatus.create(status_fields)
        if status_fields[:status] != "success"
          FillStatusesJob.create(fill_status_id: fs.id, delayed_job_id: last_job.id)
        end
      end
    end
    true
  end

  # we might want to implement the "wait" option for the "find"
  # directive (see fill_out_form_with_poltergeist)
  def fill_out_form_with_watir f={}
    b = Watir::Browser.new
    begin
      actions.order(:step).each do |a|
        case a.action
        when "visit"
          b.goto a.value
        when "wait"
          sleep a.value.to_i
        when "fill_in"
          if a.value.starts_with?("$")
            if a.value == "$CAPTCHA_SOLUTION"
              location = b.element(:css => a.captcha_selector).wd.location

              captcha_elem = b.element(:css => a.captcha_selector)
              width = captcha_elem.style("width").delete("px")
              height = captcha_elem.style("height").delete("px")

              url = self.class::save_captcha_and_store_watir b.driver, location.x, location.y, width, height

              captcha_value = yield url
              b.element(:css => a.selector).to_subtype.set(captcha_value)
            else
              if a.options
                options = YAML.load a.options
                if options.include? "max_length"
                  f[a.value] = f[a.value][0...(0.95 * options["max_length"]).floor]
                end
              end
              b.element(:css => a.selector).to_subtype.set(f[a.value].gsub("\t","    ")) unless f[a.value].nil?
            end
          else
            b.element(:css => a.selector).to_subtype.set(a.value) unless a.value.nil?
          end
        when "select"
          begin
            if f[a.value].nil?
              unless PLACEHOLDER_VALUES.include? a.value
                elem = b.element(:css => a.selector).to_subtype
                begin
                  elem.select_value(a.value)
                rescue Watir::Exception::NoValueFoundException
                  elem.select(a.value)
                end
              end
            else
              elem = b.element(:css => a.selector).to_subtype
              begin
                elem.select_value(f[a.value])
              rescue Watir::Exception::NoValueFoundException
                elem.select(f[a.value])
              end
            end
          rescue Watir::Exception::NoValueFoundException => e
            raise e, e.message unless a.options == "DEPENDENT"
          end
        when "click_on"
          b.element(:css => a.selector).to_subtype.click
        when "find"
          if a.value.nil?
            b.element(:css => a.selector).wait_until_present
          else
            b.element(:css => a.selector).wait_until_present
            b.element(:css => a.selector).parent.wait_until_present
            b.element(:css => a.selector).parent.element(:text => Regexp.compile(a.value)).wait_until_present
          end
        when "check"
          b.element(:css => a.selector).to_subtype.set
        when "uncheck"
          b.element(:css => a.selector).to_subtype.clear
        when "choose"
          if a.options.nil?
            b.element(:css => a.selector).to_subtype.set
          else
            b.element(:css => a.selector + '[value="' + f[a.value].gsub('"', '\"') + '"]').to_subtype.set
          end
        when "javascript"
          b.execute_script(a.value)
        when "recaptcha"
          sleep 100
        end
      end

      success = check_success b.text

      success_hash = {success: success}
      success_hash[:screenshot] = self.class::save_screenshot_and_store_watir(b.driver) if !success
      success_hash
    rescue Exception => e
      message = {message: e.message}
      message[:screenshot] = self.class::save_screenshot_and_store_watir(b.driver)
      raise e, YAML.dump(message)
    ensure
      b.close
    end
  end

  DEFAULT_FIND_WAIT_TIME = 5  

  def fill_out_form_with_poltergeist f={}, &block
    fill_out_form_with_capybara f, :poltergeist, &block
  end

  def fill_out_form_with_webkit f={}, &block
    fill_out_form_with_capybara f, :webkit, &block
  end

  def fill_out_form_with_capybara f={}, driver
    session = CapybaraPool.get_session(driver)
    if has_google_recaptcha?
      case driver
      when :poltergeist
        session.driver.headers = { 'User-Agent' => "Lynx/2.8.8dev.3 libwww-FM/2.14 SSL-MM/1.4.1"}
        session.driver.timeout = 4 # needed in case some iframes don't respond
      when :webkit
        session.driver.header 'User-Agent' , "Lynx/2.8.8dev.3 libwww-FM/2.14 SSL-MM/1.4.1"
      end
    end

    begin
      actions.order(:step).each do |a|
        case a.action
        when "visit"
          session.visit(a.value)
        when "wait"
          sleep a.value.to_i
        when "fill_in"
          if a.value.starts_with?("$")
            if a.value == "$CAPTCHA_SOLUTION"
              if a.options and a.options["google_recaptcha"]
                begin
                  url = self.class::save_google_recaptcha_and_store_poltergeist(session,a.captcha_selector)
                  captcha_value = yield url
                  if captcha_value == false
                    break # finish_workflow has been called
                  end
                  # We can not directly reference the captcha id due to problem stated in https://github.com/EFForg/phantom-of-the-capitol/pull/74#issuecomment-139127811
                  session.within_frame(recaptcha_frame_index(session)) do
                    for i in captcha_value.split(",")
                      session.execute_script("document.querySelector('.fbc-imageselect-checkbox-#{i}').checked=true")
                    end
                    sleep 0.5
                    session.find(".fbc-button-verify input").trigger('click')
                    @recaptcha_value = session.find("textarea").value
                  end
                  session.fill_in(a.name,with:@recaptcha_value)
                rescue Exception => e
                  retry
                end
              else
                location = CAPTCHA_LOCATIONS.keys.include?(bioguide_id) ? CAPTCHA_LOCATIONS[bioguide_id] : session.driver.evaluate_script('document.querySelector("' + a.captcha_selector.gsub('"', '\"') + '").getBoundingClientRect();')
                url = self.class::save_captcha_and_store_poltergeist session, location["left"], location["top"], location["width"], location["height"]

                captcha_value = yield url
                if captcha_value == false
                  break # finish_workflow has been called
                end
                session.find(a.selector).set(captcha_value)
              end
            else
              if a.options
                options = YAML.load a.options
                if options.include? "max_length"
                  f[a.value] = f[a.value][0...(0.95 * options["max_length"]).floor] unless f[a.value].nil?
                end
              end
              session.find(a.selector).set(f[a.value].gsub("\t","    ")) unless f[a.value].nil?
            end
          else
            session.find(a.selector).set(a.value) unless a.value.nil?
          end
        when "select"
          begin
            session.within a.selector do
              if f[a.value].nil?
                unless PLACEHOLDER_VALUES.include? a.value
                  begin
                    elem = session.find('option[value="' + a.value.gsub('"', '\"') + '"]')
                  rescue Capybara::Ambiguous
                    elem = session.first('option[value="' + a.value.gsub('"', '\"') + '"]')
                  rescue Capybara::ElementNotFound
                    begin
                      elem = session.find('option', text: Regexp.compile("^" + Regexp.escape(a.value) + "$"))
                    rescue Capybara::Ambiguous
                      elem = session.first('option', text: Regexp.compile("^" + Regexp.escape(a.value) + "$"))
                    end
                  end
                  elem.select_option
                end
              else
                begin
                  elem = session.find('option[value="' + f[a.value].gsub('"', '\"') + '"]')
                rescue Capybara::Ambiguous
                  elem = session.first('option[value="' + f[a.value].gsub('"', '\"') + '"]')
                rescue Capybara::ElementNotFound
                  begin
                    elem = session.find('option', text: Regexp.compile("^" + Regexp.escape(f[a.value]) + "$"))
                  rescue Capybara::Ambiguous
                    elem = session.first('option', text: Regexp.compile("^" + Regexp.escape(f[a.value]) + "$"))
                  end
                end
                elem.select_option
              end
            end
          rescue Capybara::ElementNotFound => e
            raise e, e.message unless a.options == "DEPENDENT"
          end
        when "click_on"
          session.find(a.selector).click
        when "find"
          wait_val = DEFAULT_FIND_WAIT_TIME
          if a.options
            options_hash = YAML.load a.options
            wait_val = options_hash['wait'] || DEFAULT_FIND_WAIT_TIME
          end
          if a.value.nil?
            session.find(a.selector, wait: wait_val)
          else
            session.find(a.selector, text: Regexp.compile(a.value), wait: wait_val)
          end
        when "check"
          session.find(a.selector).set(true)
        when "uncheck"
          session.find(a.selector).set(false)
        when "choose"
          if a.options.nil?
            session.find(a.selector).set(true)
          else
            session.find(a.selector + '[value="' + f[a.value].gsub('"', '\"') + '"]').set(true)
          end
        when "javascript"
          session.driver.evaluate_script(a.value)
        when "recaptcha"
          raise
        end
      end

      success = check_success session.text

      success_hash = {success: success}
      success_hash[:screenshot] = self.class::save_screenshot_and_store_poltergeist(session) if !success
      success_hash
    rescue Exception => e
      message = {message: e.message}
      message[:screenshot] = self.class::save_screenshot_and_store_poltergeist(session)
      raise e, YAML.dump(message)
    end
  end

  def recaptcha_frame_index(session)
    num_frames = session.evaluate_script("window.frames.length")
    (0...num_frames).each do |frame_index|
      begin
        if session.within_frame(frame_index){session.current_url} =~ /recaptcha/
          return frame_index
        end
      rescue
      end
    end
    raise
  end

  def self.crop_screenshot_from_coords screenshot_location, x, y, width, height
    img = MiniMagick::Image.open(screenshot_location)
    img.crop width.to_s + 'x' + height.to_s + "+" + x.to_s + "+" + y.to_s
    img.write screenshot_location
  end

  def self.store_captcha_from_location location
    c = CaptchaUploader.new
    c.store!(File.open(location))
    c.url
  end

  def self.store_screenshot_from_location location
    s = ScreenshotUploader.new
    s.store!(File.open(location))
    s.url
  end

  def self.save_screenshot_and_store_watir driver
    screenshot_location = random_screenshot_location
    driver.save_screenshot(screenshot_location)
    url = store_screenshot_from_location screenshot_location
    File.unlink screenshot_location
    url
  end

  def self.save_screenshot_and_store_poltergeist session
    screenshot_location = random_screenshot_location
    session.save_screenshot(screenshot_location, full: true)
    url = store_screenshot_from_location screenshot_location
    File.unlink screenshot_location
    url
  end

  def self.save_captcha_and_store_watir driver, x, y, width, height 
    screenshot_location = random_captcha_location
    driver.save_screenshot(screenshot_location)
    crop_screenshot_from_coords screenshot_location, x, y, width, height
    url = store_captcha_from_location screenshot_location
    File.unlink screenshot_location
    url
  end

  def self.save_captcha_and_store_poltergeist session, x, y, width, height
    screenshot_location = random_captcha_location
    session.save_screenshot(screenshot_location, full: true)
    crop_screenshot_from_coords screenshot_location, x, y, width, height
    url = store_captcha_from_location screenshot_location
    File.unlink screenshot_location
    url
  end

  def self.save_google_recaptcha_and_store_poltergeist session,selector
    screenshot_location = random_captcha_location
    session.save_screenshot(screenshot_location,selector:selector)
    url = store_captcha_from_location screenshot_location
    File.unlink screenshot_location
    url
  end

  def self.random_captcha_location
    Padrino.root + "/public/captchas/" + SecureRandom.hex(13) + ".png"
  end

  def self.random_screenshot_location
    Padrino.root + "/public/screenshots/" + SecureRandom.hex(13) + ".png"
  end

  def has_captcha?
    !actions.find_by_value("$CAPTCHA_SOLUTION").nil?
  end

  def has_google_recaptcha?
    !actions.select{|action|action.action and action.action == "recaptcha"}.empty?
  end

  def check_success body_text
    criteria = YAML.load(success_criteria)
    criteria.each do |i, v|
      case i
      when "headers"
        v.each do |hi, hv|
          case hi
          when "status"
            # TODO: check status code
          end
        end
      when "body"
        v.each do |bi, bv|
          case bi
          when "contains"
            unless body_text.include? bv
              return false
            end
          end
        end
      end
    end
    true
  end

  def recent_fill_status
    statuses = recent_fill_statuses
    {
      successes: statuses.success.count,
      errors: statuses.error.count,
      failures: statuses.failure.count
    }
  end

  def self.to_hash cm_array
    cm_hash = {}
    cm_array.each do |cm|
      cm_hash[cm.id.to_s] = cm
    end
    cm_hash
  end

  def self.retrieve_cached cm_hash, cm_id
    return cm_hash[cm_id] if cm_hash.include? cm_id
    cm_hash[cm_id] = self.find(cm_id)
  end

  def self.list_with_job_count cm_array
    members_ordered = cm_array.order(:bioguide_id)
    cms = members_ordered.as_json(only: :bioguide_id)

    jobs = Delayed::Job.where(queue: "error_or_failure")

    cm_hash = self.to_hash members_ordered
    people = DelayedJobHelper::tabulate_jobs_by_member jobs, cm_hash

    people.each do |bioguide, jobs_count|
      cms.select{ |cm| cm["bioguide_id"] == bioguide }.each do |cm|
        cm["jobs"] = jobs_count
      end
    end
    cms.to_json
  end

end


