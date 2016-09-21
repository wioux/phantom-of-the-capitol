require File.expand_path("../../config/boot.rb", __FILE__)
require File.expand_path("../../app/helpers/states.rb", __FILE__)
require File.expand_path("../../app/helpers/colorize.rb", __FILE__)
require File.expand_path("../../app/helpers/delayed_job_helper.rb", __FILE__)
require File.expand_path("../../app/helpers/capybara_pool.rb", __FILE__)

namespace :'phantom-dc' do
  namespace :'delayed_job' do
    desc "perform all fills on the Delayed::Job error_or_failure queue, captchad fills first, optionally provide bioguide regex, job id or activate recaptcha fills mode"
    task :perform_fills, :regex, :job_id, :overrides, :recaptcha_mode do |t, args|
      require 'pp'

      regex = args[:regex].blank? ? nil : Regexp.compile(args[:regex])
      overrides = args[:overrides].blank? ? {} : eval(args[:overrides])

      jobs = retrieve_jobs args

      recaptcha_jobs = []
      captcha_jobs = []
      noncaptcha_jobs = []

      cm_hash = CongressMember::to_hash CongressMember.all
      captcha_hash,recaptcha_hash = build_captcha_hash

      jobs.each do |job|
        cm_id, cm_args = DelayedJobHelper::congress_member_id_and_args_from_handler(job.handler)
        unless cm_args[1] == "rake" and args[:job_id].nil?
          cm = CongressMember::retrieve_cached(cm_hash, cm_id)

          if regex.nil? or regex.match(cm.bioguide_id)
            if retrieve_captchad_cached(recaptcha_hash, cm.id)
              recaptcha_jobs.push job
            elsif retrieve_captchad_cached(captcha_hash, cm.id)
              captcha_jobs.push job
            else
              noncaptcha_jobs.push job
            end
          end
        end
      end

      if args[:recaptcha_mode].present?
        recaptcha_jobs.each do |job|
          begin
            cm_id, cm_args = DelayedJobHelper::congress_member_id_and_args_from_handler(job.handler)
            cm = CongressMember::retrieve_cached(cm_hash, cm_id)
            puts red("Job #" + job.id.to_s + ", bioguide " + cm.bioguide_id)
            pp cm_args
            result = cm.fill_out_form_with_watir cm_args[0].merge(overrides)
          rescue
          end
          DelayedJobHelper::destroy_job_and_dependents job
        end
        exit
      end
      captcha_jobs.each do |job|
        begin
          cm_id, cm_args = DelayedJobHelper::congress_member_id_and_args_from_handler(job.handler)
          cm = CongressMember::retrieve_cached(cm_hash, cm_id)
          puts red("Job #" + job.id.to_s + ", bioguide " + cm.bioguide_id)
          pp cm_args
          result = cm.fill_out_form cm_args[0].merge(overrides), cm_args[1] do |img|
            puts img
            STDIN.gets.strip
          end
        rescue
        end
        DelayedJobHelper::destroy_job_and_dependents job
      end
      noncaptcha_jobs.each do |job|
        begin
          cm_id, cm_args = DelayedJobHelper::congress_member_id_and_args_from_handler(job.handler)
          cm = CongressMember::retrieve_cached(cm_hash, cm_id)
          puts red("Job #" + job.id.to_s + ", bioguide " + cm.bioguide_id)
          pp cm_args
          result = cm.fill_out_form cm_args[0].merge(overrides), cm_args[1]
        rescue
        end
        DelayedJobHelper::destroy_job_and_dependents job
      end
    end
    desc "perform recaptcha fills by hand using watir, optionally provide bioguide regex or job id"
    task :perform_recaptcha_fills, :regex, :job_id, :overrides do |t,args|
      Rake::Task['phantom-dc:delayed_job:perform_fills'].invoke(args[:regex],args[:job_id],args[:overrides],true)
    end
    desc "override a field on the Delayed::Job error_or_failure queue, optionally provide bioguide regex or job id"
    task :override_field, :regex, :job_id, :overrides, :conditions do |t, args|
      regex = args[:regex].blank? ? nil : Regexp.compile(args[:regex])
      overrides = args[:overrides].blank? ? {} : eval(args[:overrides])
      conditions = args[:conditions].blank? ? {} : eval(args[:conditions])

      jobs = retrieve_jobs args

      cm_hash = CongressMember::to_hash CongressMember.all

      jobs.each do |job|
        cm_id, = DelayedJobHelper::congress_member_id_and_args_from_handler(job.handler)
        cm = CongressMember::retrieve_cached(cm_hash, cm_id)

        if regex.nil? or regex.match(cm.bioguide_id)
          handler = YAML.load job.handler
          if conditions.all?{ |k, v| handler.args[0][k] == v }
            handler.args[0] = handler.args[0].merge(overrides)
            job.handler = YAML.dump handler
            job.save
          end
        end
      end
    end
    desc "destroy all fills on the Delayed::Job error_or_failure queue provided a specific bioguide or job_id"
    task :destroy_fills, :bioguide, :job_id do |t, args|
      cm = CongressMember.bioguide(args[:bioguide])

      jobs = retrieve_jobs args

      jobs.each do |job|
        cm_id, = DelayedJobHelper::congress_member_id_and_args_from_handler(job.handler)
        if not args[:job_id].nil? or cm_id.to_i == cm.id
          puts red("Destroying job #" + job.id.to_s)
          DelayedJobHelper::destroy_job_and_dependents job
        end
      end
    end
    desc "calculate # of jobs per member on the Delayed::Job error_or_failure queue"
    task :jobs_per_member do |t, args|
      jobs = Delayed::Job.where(queue: "error_or_failure")
      cm_hash = CongressMember::to_hash CongressMember.all
      people = DelayedJobHelper::tabulate_jobs_by_member jobs, cm_hash

      captchad_hash = {}
      total_captchad_jobs = 0
      total_jobs = 0
      people.each do |k, v|
        if CongressMember.bioguide(k).has_captcha?
          captchad_hash[k] = true
          total_captchad_jobs += v
        end
        total_jobs += v
      end
      puts "The captcha'd congress members are displayed in red.\n\n"
      people.sort_by { |k, v| v}.reverse.each do |k, v|
        key_colored = captchad_hash[k] ? red(k) : k
        puts key_colored + ": " + v.to_s
      end
      puts "\nTotal jobs: "+total_jobs.to_s
      puts "Total captcha'd jobs: "+total_captchad_jobs.to_s
      puts "\nTotal members: "+people.length.to_s
      puts "Total captcha'd members: "+captchad_hash.length.to_s
    end
    desc "for error_or_failure jobs that have no zip4, look up the zip4, save, and retry"
    task :zip4_retry, :regex do |t, args|
      regex = args[:regex].blank? ? nil : Regexp.compile(args[:regex])

      jobs = Delayed::Job.where(queue: "error_or_failure")

      cm_hash = CongressMember::to_hash CongressMember.all

      non_zip4_jobs = []
      jobs.each do |job|
        cm_id, cm_args = DelayedJobHelper::congress_member_id_and_args_from_handler(job.handler)
        cm = CongressMember::retrieve_cached(cm_hash, cm_id)
        if regex.nil? or regex.match(cm.bioguide_id)
          if cm_args[0]['$ADDRESS_ZIP4'].nil?
            non_zip4_jobs.push job
          end
        end
      end
      puts "# of jobs without zip4: " + non_zip4_jobs.count.to_s
      non_zip4_jobs.each do |job|
        handler = YAML.load job.handler
        puts red("Job #" + job.id.to_s + ", bioguide " + handler.object.bioguide_id)
        begin
          locations = SmartyStreets.standardize do |l|
            l.street = handler.args[0]['$ADDRESS_STREET'] + ", " + handler.args[0]['$ADDRESS_ZIP5']
          end
          raise SmartyStreets::Request::NoValidCandidates if locations.empty?
          handler.args[0]['$ADDRESS_ZIP4'] = locations.first.components["plus4_code"]
        rescue SmartyStreets::Request::NoValidCandidates
          puts "Please enter the zip+4 for the following address:\n" + handler.args[0]['$ADDRESS_STREET'] + ", " + handler.args[0]['$ADDRESS_ZIP5']
          handler.args[0]['$ADDRESS_ZIP4'] = STDIN.gets.strip
        end
        job.handler = YAML.dump(handler)
        job.save
        begin
          result = handler.object.fill_out_form handler.args[0], handler.args[1] do |img|
            puts img
            STDIN.gets.strip
          end
        rescue
        end
        DelayedJobHelper::destroy_job_and_dependents job
      end
    end
    desc "delete jobs that were generated during the fill_out_all rake task"
    task :delete_rake do |t, args|
      jobs = Delayed::Job.where(queue: "error_or_failure")
      jobs.each do |job|
        handler = YAML.load job.handler
        DelayedJobHelper::destroy_job_and_dependents(job) if handler.args[1] == "rake"
      end
    end
    desc "fix duplicate values of any field: choose the first one"
    task :fix_duplicates, :field, :regex do |t, args|
      regex = args[:regex].blank? ? nil : Regexp.compile(args[:regex])

      jobs = Delayed::Job.where(queue: "error_or_failure")

      cm_hash = CongressMember::to_hash CongressMember.all

      duplicate_jobs = []
      jobs.each do |job|
        cm_id, cm_args = DelayedJobHelper::congress_member_id_and_args_from_handler(job.handler)
        cm = CongressMember::retrieve_cached(cm_hash, cm_id)
        if regex.nil? or regex.match(cm.bioguide_id)
          field = cm_args[0][args[:field]]
          if field.is_a? Array
            duplicate_jobs.push job
          end
        end
      end
      puts "# of jobs with dubplicates: " + duplicate_jobs.count.to_s
      duplicate_jobs.each do |job|
        handler = YAML.load job.handler
        puts red("Fixing job #" + job.id.to_s + ", bioguide " + handler.object.bioguide_id)
        handler.args[0][args[:field]] = handler.args[0][args[:field]].first
        job.handler = YAML.dump(handler)
        job.save
      end
    end

  end
  desc "Git pull and reload changed CongressMember records into db"
  task :update_git do |t, args|

    DataSource.all.each do |ds|
      g = Git.open ds.path
      g.pull

      update_db_with_git_object g, ds
    end
  end
  desc "Reload CongressMember record into db given data source and bioguide regex"
  task :update_member, :data_source_name, :regex do |t, args|
    data_source = args[:data_source_name].blank? ? nil : DataSource.find_by_name(args[:data_source_name])
    cm = args[:regex].blank? ? [] : CongressMember.where("bioguide_id REGEXP '" + args[:regex].gsub("'","") + "'")

    cm.each do |c|
      f = data_source.path + '/' + data_source.yaml_subpath + '/' + c.bioguide_id + '.yaml'
      update_db_member_by_file f, data_source.prefix
    end
  end
  desc "Set updated at for congress members"
  task :updated_at, :regex, :time do |t, args|
    time = args[:time].blank? ? Time.now : eval(args[:time])

    cm = args[:regex].blank? ? CongressMember.all : CongressMember.where("bioguide_id REGEXP '" + args[:regex].gsub("'","") + "'")
    cm.each do |c|
      c.updated_at = time
      c.save
    end
  end
  desc "Analyze how common the expected values of fields are"
  task :common_fields do |t, args|
    values_hash = {}
    required_hash = {}
    congress_hash = {}

    all_members = CongressMember.all
    all_members.each do |c|
      congress_hash[c.bioguide_id] = {}
      c.actions.each do |a|
        if congress_hash[c.bioguide_id][a.value].nil? && a.value.to_s.start_with?("$")
          values_hash[a.value] = (values_hash[a.value].nil? ? 1 : values_hash[a.value] + 1)
          required_hash[a.value] = (required_hash[a.value].nil? ? 1 : required_hash[a.value] + 1) if a.required
          congress_hash[c.bioguide_id][a.value] = true
        end
      end
    end
    puts "Percent of congress members contact forms the common fields appear on:"
    puts "Format given as '$VAR_NAME : PERCENT_PRESENT (PERCENT_REQUIRED)\n\n"
    values_hash = values_hash.select{ |i, v| v >= all_members.count * 0.1 } # only show values that appear in >= 10% of congressmembers
    values_arr = values_hash.sort_by{|i, v| v}.reverse!
    values_arr.each do |v|
      appears_percent = v[1] * 100 / all_members.count
      required_percent = required_hash[v[0]] * 100 / all_members.count
      puts v[0] + " : " + appears_percent.to_s + "% (" + required_percent.to_s + "%)"
    end
  end
  desc "Run through filling out of all congress members"
  task :fill_out_all, :regex do |t, args|
    response = Typhoeus.get("https://raw.githubusercontent.com/EFForg/congress-zip-plus-four/master/legislators.json")
    congress_defaults = JSON.parse(response.body.gsub(/^define\(|\)$/, ''))

    response = Typhoeus.get("https://raw.githubusercontent.com/unitedstates/contact-congress/master/support/variables.yaml")
    defaults = YAML.load(response.body)

    possible_validation = {
      "$ADDRESS_STREET" => "example_address",
      "$ADDRESS_CITY" => "example_city",
      "$ADDRESS_STATE_POSTAL_ABBREV" => "example_state",
      "$ADDRESS_STATE_FULL" => "example_state"
    }

    captchad = []
    noncaptchad = []
    notfound = []

    cm = args[:regex].blank? ? CongressMember.all : CongressMember.where("bioguide_id REGEXP '" + args[:regex].gsub("'","") + "'")
    cm.each do |c|
      if congress_defaults.include? c.bioguide_id
        if !c.has_captcha?
          noncaptchad.push(c) 
        else
          captchad.push(c)
        end
      else
        notfound.push(c.bioguide_id)
      end
    end

    (captchad + noncaptchad).each do |c|
      fields_hash = {}

      fields_hash["$ADDRESS_ZIP4"] = congress_defaults[c.bioguide_id]["zip4"] || defaults["$ADDRESS_ZIP4"]["example"]
      fields_hash["$ADDRESS_ZIP5"] = congress_defaults[c.bioguide_id]["zip5"] || defaults["$ADDRESS_ZIP5"]["example"]

      c.required_actions.each do |ra|
        if ra.value == "$ADDRESS_ZIP4" or ra.value == "$ADDRESS_ZIP5"
        elsif possible_validation.keys.include? ra.value
          if ra.value == "$ADDRESS_STATE_FULL"
            fields_hash[ra.value] = STATES[congress_defaults[c.bioguide_id][possible_validation[ra.value]]] || defaults[ra.value]["example"]
          else
            fields_hash[ra.value] = congress_defaults[c.bioguide_id][possible_validation[ra.value]] || defaults[ra.value]["example"]
          end
        elsif defaults.keys.include? ra.value
          if ra.options.nil?
            fields_hash[ra.value] = defaults[ra.value]["example"]
          else
            options = YAML.load(ra.options)
            values = options.is_a?(Hash) ? options.values : options

            #if values.include? defaults[ra.value]["example"]
              #fields_hash[ra.value] = defaults[ra.value]["example"]
            #else

            fields_hash[ra.value] = values[Random.rand(values.length)]

            #end
          end
        end
      end
      begin
        c.fill_out_form fields_hash, "rake" do |c|
          puts "Please type in the value for the captcha at " + c + "\n"
          STDIN.gets.strip
        end
      rescue
      end
    end

    puts "No congressional defaults found for the following members: " + notfound.inspect
  end
end

def update_db_with_git_object g, data_source
    current_commit = data_source.latest_commit

    new_commit = g.log.first.sha

    if current_commit == new_commit
      puts data_source.name + ": Already at latest commit. Aborting!"
    else
      if current_commit.nil?
        files_changed = Dir[data_source.path + '/' + data_source.yaml_subpath + '/*.yaml'].map { |d| d.sub(data_source.path, "") }
        puts data_source.name + "No previous commit found, reloading all congress members into db"
      else
        files_changed = g.diff(current_commit, new_commit).path(data_source.yaml_subpath).map { |d| d.path }
        puts files_changed.count.to_s + " congress members form files have changed between commits " + current_commit.to_s + " and " + new_commit
      end


      files_changed.each do |file_changed|
        f = data_source.path + '/' + file_changed
        update_db_member_by_file f, data_source.prefix
      end
      
      data_source.latest_commit = new_commit
      data_source.save
    end
end

def update_db_member_by_file f, prefix
  create_congress_member_exception_wrapper(f) do
    begin
      congress_member_details = YAML.load_file(f)
      bioguide = congress_member_details["bioguide"]
      CongressMember.find_or_create_by(bioguide_id: prefix + bioguide).actions.each { |a| a.destroy }
      create_congress_member_from_hash congress_member_details, prefix
    rescue Errno::ENOENT
      puts "File " + f + " is missing, skipping..."
    rescue NoMethodError
      puts "File " + f + " does not have a bioguide defined, skipping..."
    end
  end
end

def create_congress_member_exception_wrapper file_path
  begin
    yield
  rescue Psych::SyntaxError => exception
    puts ""
    puts "File "+file_path+" could not be parsed"
    puts "  Problem: "+exception.problem
    puts "  Line:    "+exception.line.to_s
    puts "  Column:  "+exception.column.to_s
  end
end


def create_congress_member_from_hash congress_member_details, prefix
  CongressMember.with_new_or_existing_bioguide(prefix + congress_member_details["bioguide"]) do |c|
    step_increment = 0
    congress_member_details["contact_form"]["steps"].each do |s|
      action, value = s.first
      case action
      when "visit"
        create_action_add_to_member(action, step_increment += 1, c) do |cmf|
          cmf.value = value
        end
      when "fill_in", "select", "click_on", "find", "check", "uncheck", "choose", "wait", "javascript", "recaptcha"
        value.each do |field|
          create_action_add_to_member(action, step_increment += 1, c) do |cmf|
            field.each do |attribute|
              if cmf.attributes.keys.include? attribute[0]
                cmf.update_attribute(attribute[0], attribute[1])
              end
            end
          end
        end
      end
    end
    c.success_criteria = congress_member_details["contact_form"]["success"]
    c.updated_at = Time.now
    c.save
  end
end

def create_action_add_to_member action, step, member
  cmf = CongressMemberAction.new(:action => action, :step => step)
  yield cmf
  cmf.congress_member = member
  cmf.save
end

def retrieve_captchad_cached captcha_hash, cm_id
  return captcha_hash[cm_id] if captcha_hash.include? cm_id
  return false
  #captcha_hash[cm_id] = CongressMember.find(cm_id).has_captcha?
end

def build_captcha_hash
  captcha_hash = {}
  CongressMemberAction.where(value: "$CAPTCHA_SOLUTION").each do |cma|
    captcha_hash[cma.congress_member_id] = true
  end

  recaptcha_hash = {}
  CongressMemberAction.where(action: "recaptcha").each do |cma|
    recaptcha_hash[cma.congress_member_id] = true
  end
  [captcha_hash,recaptcha_hash]
end

def retrieve_jobs args
  job_id = args[:job_id].blank? ? nil : args[:job_id].to_i

  if job_id.nil?
    Delayed::Job.where(queue: "error_or_failure")
  else
    [Delayed::Job.find(job_id)]
  end
end
