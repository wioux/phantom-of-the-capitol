module CapybaraPool
  @sessions = {}

  def self.get_session(driver)
    @sessions[driver] ||= Capybara::Session.new(driver).tap do |session|
      if driver == :poltergeist
        session.driver.options[:js_errors] = false
        session.driver.options[:phantomjs_options] = ['--ssl-protocol=TLSv1']
      end
    end

    @sessions[driver].tap(&:reset!)
  end
end
