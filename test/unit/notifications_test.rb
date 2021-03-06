require "test_helper"
require 'notifications'


class NotificationsTest < ActiveRecord::TestCase
  FIXTURES_PATH = File.dirname(__FILE__) + '/../fixtures'
  CHARSET = "UTF-8"
  fixtures :users, :tasks, :projects, :customers, :companies

  context "a normal notification" do
    setup do
      # need to hard code these configs because the fixtured have hard coded values
      $CONFIG[:domain] = "clockingit.com"
      $CONFIG[:email_domain] = $CONFIG[:domain].gsub(/:\d+/, '')
      $CONFIG[:productName] = "Jobsworth"

      @expected = Mail.new
      @expected.set_content_type "text/plain; charset=#{CHARSET}"

      @expected.from     = "#{$CONFIG[:from]}@#{$CONFIG[:email_domain]}"
      @expected.reply_to = 'task-1@cit.clockingit.com'
      @expected.to       = 'admin@clockingit.com'
      @expected['Mime-Version'] = '1.0'
      @expected.date     = Time.now
    end

    context "with a user with access to the task" do
      setup do
        @task = tasks(:normal_task)
        @user = users(:admin)
        @user.projects<<@task.project
        @user.save!
      end

      should "create created mail as expected" do
        @expected.subject  = '[Jobsworth] Created: [#1] Test [Test Project] (Unassigned)'
        @expected.body     = read_fixture('created')
        @task.company.properties.destroy_all
        @task.company.create_default_properties
        @task.company.properties.each{ |p|
          @task.set_property_value(p, p.default_value)
        }
        notification = Notifications.create_created(@task, @user,
                                                    @task.notification_email_addresses(@user), "")
        assert_equal @task.notification_email_addresses(@user), [@user.email]
        assert @user.can_view_task?(@task)
        assert_match /tasks\/view/, notification.body.to_s
        assert_equal @expected.body.to_s, notification.body.to_s
      end

      should "create changed mail as expected" do
        @expected.subject = '[Jobsworth] Resolved: [#1] Test -> Open [Test Project] (Erlend Simonsen)'
        @expected['Mime-Version'] = '1.0'
        @expected.body    = read_fixture('changed')
        notification = Notifications.create_changed(:completed, @task, @user,
                                                    @task.notification_email_addresses(@user),
                                                    "Task Changed")
        assert @user.can_view_task?(@task)
        assert_match  /tasks\/view/,  notification.body.to_s
        assert_equal @expected.body.to_s, notification.body.to_s
      end

      should "not escape html in email" do
        html = '<strong> HTML </strong> <script type = "text/javascript"> alert("XSS");</script>'
        notification = Notifications.create_changed(:changed, @task, @user, @task.notification_email_addresses(@user), html)
        assert_not_nil notification.body.to_s.index(html)
      end

      should "should have 'text/plain' context type" do
        notification = Notifications.create_changed(:changed, @task, @user, @task.notification_email_addresses(@user), "Task changed")
        assert_match /text\/plain/, notification.content_type
      end
    end

    context "a user without access to the task" do
      setup do
        @task = tasks(:normal_task)
        @user = users(:tester)
        @user.project_permissions.destroy_all
        assert !@task.project.users.include?(@user)
      end

      should "create changed mail without view task link" do
        notification = Notifications.create_changed(:completed, @task, @user,
                                                    @task.notification_email_addresses(@user),
                                                    "Task Changed")
        assert_nil notification.body.to_s.index("/tasks/view/")
      end

      should "create created mail without view task link" do
        notification = Notifications.create_created(@task, @user,
                                                    @task.notification_email_addresses(@user),
                                                    "")
        assert_nil notification.body.to_s.index("/tasks/view/")
      end
    end
  end

  private
  def read_fixture(action)
    File.open("#{FIXTURES_PATH}/notifications/#{action}").read
  end

  def encode(subject)
    quoted_printable(subject, CHARSET)
  end
end

