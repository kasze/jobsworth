# encoding: UTF-8
# Receive and handle emails sent to tasks

class Mailman < ActionMailer::Base
  # The marker in the email body that shows where the new content ends
  BODY_SPLIT = "o------ please reply above this line ------o"

  ### Mailman::Email provides a way to extract content from incoming email
  class Email
    attr_accessor :to, :from, :body, :subject, :user, :company, :email_address
    def initialize(email)
      @to, @from = email.to.join(", "), email.from.join(", ")
      @body, @subject = get_body(email), email.subject
      @email_address = EmailAddress.find_or_create_by_email(@from)
    end

    private
    def get_body(email)
      body = nil

      if email.multipart? then
        email.parts.each do |m|
          next if body

          if m.content_type =~ /text\/plain/i
            body = m.body.to_s
          elsif m.multipart?
            body = get_body(m)
          end
        end
      end

      body ||= email.body.to_s
      body = Mailman.clean_body(body)
      body = CGI::escapeHTML(body)
      return body
    end
  end

  # helper method to remove email reply noise from the body
  def self.clean_body(body)
    new_body_end = body.to_s.index(Mailman::BODY_SPLIT) || body.to_s.length
    body = body.to_s[0, new_body_end].strip

    lines = body.to_s.split("\n")
    while lines.any?
      line = lines.last.strip

      if line.blank? or line.match(/^[<>]+$/) or line.match(/.* wrote:/)
        lines.pop
      else
        break
      end
    end

    return lines.join("\n")
  end

  def bad_subject?(sub)
    return false if sub.nil?
    arr = YAML.load_file(File.join(Rails.root, '/config/bad_subjects.yml'))
    subjects= arr["bad_subject"].collect{|s| s.strip}
    subjects.include?(sub.strip)
  end

  def receive(email)
    e = Mailman::Email.new(email)
    if e.subject.blank?
      responce_string= "the subject in your email was blank."
    end
    if e.body.blank?
      responce_string= "the body of your email was blank or you didn't reply above the line."
    end
    if email.attachments.detect { |file| file.body.to_s.size > 5*1024*1024 }
      responce_string= "you attached a file over 5Mb."
    end
    if(email.date < (Time.now- 1.week))
      responce_string= "your email was over a week old (or your clock is badly adjusted)."
    end
    if bad_subject?(e.subject)
      responce_string= "the subject of your email was empty or it was too generic without providing a summary of the issue."
    end
    if !responce_string.nil?
        Notifications.response_to_invalid_email(email.from.first, responce_string).deliver
        return false
    end
    company = nil
    (email.to+Array.wrap(email.resent_to)).each do |to|
      next unless to.include?($CONFIG[:domain])
      subdomain = to.split('@')[1].split('.')[0]
      company ||= Company.find_by_subdomain(subdomain)
    end
    # if company not found but we're using a single company install, just
    # use that one
    company ||= Company.first if Company.count == 1
    if company
      e.company = company
      e.user = User.by_email(e.from).where("company_id = ?", company.id).first
    end

    target = target_for(email, company)
    if target and target.is_a?(Task)
      add_email_to_task(e, email, target)

    elsif target and target.is_a?(Project)
      task = create_task_from_email(email, target)
      add_email_to_task(e, email, task)

    else
      Notifications.unknown_from_address(email.from.first, company.subdomain).deliver
    end
    return e
  end

  private

  # Returns the target location for the given email. Could be
  # a Task, a Project or nil.
  def target_for(email, company)
    target = nil
    (email.to+Array(email.resent_to)).each do |to|
      if to.include?("task-")
        _, task_num = /task-(\d+).*@.*/.match(to).to_a
        if task_num.to_i > 0
          target = Task.where("company_id = ? AND task_num = ?", company.id, task_num).first
        end
      end
    end

    target ||= default_project(company)
    return target
  end

  # Returns the default email project for company, or nil
  # if none.
  def default_project(company)
    id = company.preference("incoming_email_project")
    return company.projects.find_by_id(id)
  end

  def add_email_to_task(e, email, task)
    return if !should_accept_email?(email, task)
    files=[]
    if email.has_attachments?
      files= email.attachments.map do |attachment|
        add_attachment(e, task, attachment)
      end
    end

    if task.done?
      # need to reopen task so incoming comment doens't get closed
      task.update_attributes(:completed_at => nil,
                             :status => Task.status_types.index("Open"))
    end
    w = WorkLog.new(:user => e.user, :company => task.project.company,
                    :customer => task.project.customer, :email_address => e.email_address,
                    :task => task, :started_at => Time.now.utc,
                    :duration => 0, :log_type => EventLog::TASK_COMMENT,
                    :body => e.body)
    w.save

    w.event_log.user = e.user
    w.event_log.save
    send_changed_emails_for_task(w, files)
  end

  # Returns true if the email should be accepted
  def should_accept_email?(email, task)
    # for now, let's try just accepting everything
    return true
  end

  def add_attachment(e, target, attachment)
    tempfile = File.open(Rails.root.join('tmp', attachment.original_filename.gsub(' ', '_').gsub(/[^a-zA-Z0-9_\.]/, '')), 'w')
    tempfile.write_nonblock(attachment.body)
    file= target.add_attachment(File.open(tempfile.path), e.user)
    File.delete(tempfile.path)
    return file
  end

  def create_task_from_email(email, project)
    task = Task.new(:name => email.subject,
                    :project => project,
                    :company => project.company,
                    :description => "",
                    :duration => 0)
    task.set_default_properties
    begin
      task.save(:validate=>false)
    rescue ActiveRecord::RecordNotUnique
      task.save(:validate=>false)
    end
    attach_users_to_task(task, email)
    task.save(:validate=>false)
    attach_customers_to_task(task)

    # need to do without_validations to get around validation
    # errors on custom attributes
    task.save(:validate=> false)
    send_email_to_creator(task, email)

    return task
  end

  def attach_users_to_task(task, email)
    project = task.project

    (email.from || []).each do |email_addr|
      user = project.company.users.by_email(email_addr.strip).first
      task.watchers << user if user
    end
    (email.to || []).each do |email_addr|
      user = project.company.users.by_email(email_addr.strip).first
      task.owners << user if user
    end
    (email.cc || []).each do |email_addr|
      user = project.company.users.by_email(email_addr.strip).first
      task.watchers << user if user
    end
  end

  def attach_customers_to_task(task)
    task.users.each do |user|
      if user.customer and !task.customers.include?(user.customer)
        task.customers << user.customer
        user.customer.users.auto_add.each do |u|
           task.watchers << u unless task.users.include?(u)
        end
      end
    end
  end

  def send_email_to_creator(task, email)
    email_body = email.body.to_s.gsub(/<[^>]*>/,'')
    # need a user, so just use the first admin
    user = task.company.users.where(:admin => 1).first
    Notifications.created(task, user, email.from.first.strip, email_body).deliver
    task.mark_as_unread(user)
  end

  def send_changed_emails_for_task(work_log, files)
    user = work_log.user
    tmp=user.receive_own_notifications
    user.receive_own_notifications=false
    #skip save! if incoming email came from unknown user
    unless user.new_record?
      user.save!
      send_worklog_notification(work_log, files)
      user.receive_own_notifications=tmp
      user.save!
    else
      send_worklog_notification(work_log, files)
    end
  end

  def send_worklog_notification(work_log, files)
    #TODO: remove exception handling after 30/12/2010, it shouldn't raise error anymore
    begin
      work_log.notify(:comment, files)
    rescue Exception => e
      str= "body enconging #{work_log.body.encoding}"
      work_log.reload
      str += "after reload body encoding #{work_log.body.encoding}"
      raise e, e.message+str
    end
  end
end
