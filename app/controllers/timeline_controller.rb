# Filter WorkLogs in different ways, with pagination
class TimelineController < ApplicationController

  def list

    if current_user.admin == 0
      flash['notice'] = _("Sorry, only admins can use timeline in next few days.")
      redirect_to '/'
      return false
    end

    filter = ""
    @filter_params = {}

    [:filter_user, :filter_status, :filter_project, :filter_date].each do |fp|
      @filter_params[fp] = params[fp] unless params[fp].blank?
    end

    event_log_types = [ EventLog::FORUM_NEW_POST, EventLog::WIKI_CREATED,
                        EventLog::WIKI_MODIFIED, EventLog::RESOURCE_PASSWORD_REQUESTED ]
    if (event_log_types.include?(params[:filter_status].to_i) || params[:filter_status].nil? )
      filter << " AND event_logs.user_id = #{params[:filter_user]}" if params[:filter_user].to_i > 0
      filter << " AND event_logs.event_type = #{EventLog::FORUM_NEW_POST}" if params[:filter_status].to_i == EventLog::FORUM_NEW_POST
      filter << " AND event_logs.event_type = #{EventLog::WIKI_CREATED}" if params[:filter_status].to_i == EventLog::WIKI_CREATED
      filter << " AND event_logs.event_type IN (#{EventLog::WIKI_CREATED},#{EventLog::WIKI_MODIFIED})" if params[:filter_status].to_i == EventLog::WIKI_MODIFIED
      filter << " AND event_logs.event_type = #{ EventLog::RESOURCE_PASSWORD_REQUESTED }" if params[:filter_status].to_i == EventLog::RESOURCE_PASSWORD_REQUESTED
    else
      filter << " AND work_logs.user_id = #{params[:filter_user]}" if params[:filter_user].to_i > 0
      filter << " AND work_logs.log_type = #{EventLog::TASK_CREATED}" if params[:filter_status].to_i == EventLog::TASK_CREATED
      filter << " AND work_logs.log_type IN (#{EventLog::TASK_CREATED},#{EventLog::TASK_REVERTED},#{EventLog::TASK_COMPLETED})" if params[:filter_status].to_i == EventLog::TASK_REVERTED
      filter << " AND work_logs.log_type = #{EventLog::TASK_COMPLETED}" if params[:filter_status].to_i == EventLog::TASK_COMPLETED
      filter << " AND (work_logs.log_type = #{EventLog::TASK_COMMENT} OR work_logs.comment = 1)" if params[:filter_status].to_i == EventLog::TASK_COMMENT
      filter << " AND work_logs.log_type = #{EventLog::TASK_MODIFIED}" if params[:filter_status].to_i == EventLog::TASK_MODIFIED
      filter << " AND work_logs.duration > 0" if params[:filter_status].to_i == EventLog::TASK_WORK_ADDED
    end

    if  (params[:filter_date].to_i > 0) and (params[:filter_date].to_i < 7)
      name= [:'This week', :'Last week', :'This month', :'Last month', :'This year', :'Last year'][params[:filter_date].to_i-1]
      filter << " AND work_logs.started_at > '#{tz.utc_to_local(TimeRange.start_time(name)).to_s(:db)}' AND work_logs.started_at < '#{tz.utc_to_local(TimeRange.end_time(name)).to_s(:db)}'"
    end

    if params[:filter_project].to_i > 0
      filter = " AND work_logs.project_id = #{params[:filter_project]}" + filter
    else
      filter = " AND (work_logs.project_id IN (#{current_project_ids}) OR work_logs.project_id IS NULL or work_logs.project_id = 0)" + filter
    end

    if event_log_types.include?(params[:filter_status].to_i)
      filter.gsub!(/work_logs/, 'event_logs')
      filter.gsub!(/started_at/, 'created_at')

      @logs = EventLog.paginate(:all, :include => [:user], :order => "event_logs.created_at desc", :conditions => ["event_logs.company_id = ? AND if(target_type='WorkLog', (select id from work_logs where work_logs.id=event_logs.target_id and work_logs.access_level_id <= ?) , true)  #{filter}", current_user.company_id, current_user.access_level_id], :per_page => 100, :page => params[:page] )

      worklog_ids = []
      @logs.each do |l|
        if l.target_type == 'WorkLog'
          worklog_ids << l.target_id
        end
      end

      @worklogs = { }
      WorkLog.find(worklog_ids, :include => [:user, {:task => [ :milestone, :tags, :dependencies, :dependants, :users, { :project => [:customer] } ]}  ]).each do |w|
        @worklogs[w.id] = w
      end

    else
      @logs = WorkLog.level_accessed_by(current_user).paginate(:all, :order => "work_logs.started_at desc,work_logs.id desc", :conditions => ["work_logs.company_id = ? #{filter}", current_user.company_id], :include => [:user, {:task => [ :milestone, :tags, :dependencies, :dependants, :users, { :project => [:customer] } ]}], :per_page => 100, :page => params[:page] )
    end
  end

end
