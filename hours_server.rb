# Copyright 2013 Team 254. All Rights Reserved.
# @author pat@patfairbank.com (Patrick Fairbank)
#
# The main class of the hours web server.

require "active_support/time"
require "cgi"
require "cheesy-common"
require "pathological"
require "sinatra/base"
require "sinatra-websocket"

require "models"

module CheesyHours
  class Server < Sinatra::Base
    use Rack::Session::Cookie, :key => "rack.session", :expire_after => 3600

    # Enforce authentication for all non-public routes.
    before do
      @user = session[:user]
      if @user.nil?
        @user = CheesyCommon::Auth.get_user(request)
        if @user.nil?
          unless (["/", "/signin", "/sms", "/tag/live", "/tag_ws"].include?(request.path) ||
              request.path.include?("tag/event"))
            redirect "#{CheesyCommon::Config.members_url}?site=hours&path=#{request.path}"
          end
        else
          session[:user] = @user
        end
      end
    end

    get "/logout" do
      session[:user] = nil
      redirect "#{CheesyCommon::Config.members_url}/logout"
    end

    get "/" do
      @signed_in_sessions = LabSession.where(:time_out => nil)
      erb :index
    end

    post "/signin" do
      @student = Student.get_by_id(params[:student_id])
      halt(400, "Invalid student.") if @student.nil?

      # Restrict sign-ins to the lab's IP address ranges.
      ip_whitelist = CheesyCommon::Config.signin_ip_whitelist
      if !ip_whitelist.empty? && ip_whitelist.none? { |ip| request.env["HTTP_X_REAL_IP"].start_with?(ip) }
        halt(400, "Invalid IP address. Must sign in from the Robotics Lab.")
      end

      # Check for existing open lab sessions.
      unless LabSession.where(:student_id => @student.id, :time_out => nil).empty?
        halt(400, "An open lab session already exists for student #{@student.id}.")
      end
      @student.add_lab_session(:time_in => Time.now)

      redirect "/"
    end

    get "/leader_board" do
      erb :leader_board
    end

    get "/students/:id" do
      @student = Student[params[:id]]
      halt(400, "Invalid student.") if @student.nil?
      erb :student
    end

    get "/students/:id/new_lab_session" do
      halt(403, "Insufficient permissions.") unless @user.has_permission?("HOURS_EDIT")
      @student = Student[params[:id]]
      halt(400, "Invalid student.") if @student.nil?
      erb :edit_lab_session
    end

    post "/students/:id/new_lab_session" do
      halt(403, "Insufficient permissions.") unless @user.has_permission?("HOURS_EDIT")
      student = Student[params[:id]]
      halt(400, "Invalid student.") if student.nil?
      student.add_lab_session(:time_in => params[:time_in], :time_out => params[:time_out],
                              :notes => params[:notes],
                              :mentor_name => params[:time_out].empty? ? nil : @user.name_display)
      redirect params[:referrer] || "/leader_board"
    end

    get "/lab_sessions/:id/edit" do
      halt(403, "Insufficient permissions.") unless @user.has_permission?("HOURS_EDIT")
      @lab_session = LabSession[params[:id]]
      halt(400, "Invalid lab session.") if @lab_session.nil?
      @referrer = request.referrer
      erb :edit_lab_session
    end

    post "/lab_sessions/:id/edit" do
      halt(403, "Insufficient permissions.") unless @user.has_permission?("HOURS_EDIT")
      @lab_session = LabSession[params[:id]]
      halt(400, "Invalid lab session.") if @lab_session.nil?
      if !params[:time_out].empty? && @lab_session.time_out.nil?
        mentor_name = @user.name_display
      elsif params[:time_out].empty? && @lab_session.time_out
        mentor_name = nil
      else
        mentor_name = @lab_session.mentor_name
      end
      @lab_session.update(:time_in => params[:time_in], :time_out => params[:time_out],
                          :notes => params[:notes], :mentor_name => mentor_name)
      redirect params[:referrer] || "/leader_board"
    end

    get "/lab_sessions/:id/delete" do
      halt(403, "Insufficient permissions.") unless @user.has_permission?("HOURS_EDIT")
      @lab_session = LabSession[params[:id]]
      halt(400, "Invalid lab session.") if @lab_session.nil?
      @referrer = request.referrer
      erb :delete_lab_session
    end

    post "/lab_sessions/:id/delete" do
      halt(403, "Insufficient permissions.") unless @user.has_permission?("HOURS_EDIT")
      @lab_session = LabSession[params[:id]]
      halt(400, "Invalid lab session.") if @lab_session.nil?
      @lab_session.delete
      redirect params[:referrer] || "/leader_board"
    end

    get "/lab_sessions/:id/sign_out" do
      halt(403, "Insufficient permissions.") unless @user.has_permission?("HOURS_EDIT")
      lab_session = LabSession[params[:id]]
      halt(400, "Invalid lab session.") if lab_session.nil?
      lab_session.update(:time_out => Time.now, :mentor_name => @user.name_display)
      redirect "/"
    end

    get "/lab_sessions/open" do
      @signed_in_sessions = LabSession.where(:time_out => nil).order(:id)
      erb :signed_in_list
    end

    get "/new_mentor" do
      halt(403, "Insufficient permissions.") unless @user.has_permission?("HOURS_EDIT")
      erb :new_mentor
    end

    get "/mentors" do
      halt(403, "Insufficient permissions.") unless @user.has_permission?("HOURS_EDIT")
      erb :mentors
    end

    post "/mentors" do
      halt(403, "Insufficient permissions.") unless @user.has_permission?("HOURS_EDIT")
      halt(400, "Missing first name.") if params[:first_name].nil? || params[:first_name].empty?
      halt(400, "Missing last name.") if params[:last_name].nil? || params[:last_name].empty?
      halt(400, "Missing phone number.") if params[:phone_number].nil? || params[:phone_number].empty?
      Mentor.create(:first_name => params[:first_name], :last_name => params[:last_name],
                    :phone_number => params[:phone_number].gsub(/[^\d]/, "")[-10..-1])
      redirect "/mentors"
    end

    get "/mentors/:id/delete" do
      halt(403, "Insufficient permissions.") unless @user.has_permission?("HOURS_EDIT")
      @mentor = Mentor[params[:id]]
      halt(400, "Invalid mentor.") if @mentor.nil?
      erb :delete_mentor
    end

    post "/mentors/:id/delete" do
      halt(403, "Insufficient permissions.") unless @user.has_permission?("HOURS_EDIT")
      @mentor = Mentor[params[:id]]
      halt(400, "Invalid mentor.") if @mentor.nil?
      @mentor.delete
      redirect "/mentors"
    end

    # Receives all SMS messages via Twilio.
    post "/sms" do
      content_type "application/xml"

      # Retrieve the mentor record using the sender phone number.
      phone_number = params[:From].gsub(/[^\d]/, "")[-10..-1]
      mentor = Mentor.where(:phone_number => phone_number).first
      halt(200, sms_response(["Error: Don't recognize sender's phone number."])) if mentor.nil?

      # First check for special control messages.
      if params[:Body].downcase == "gtfo"
        # Sign everyone out all at once.
        LabSession.where(:time_out => nil).each do |lab_session|
          lab_session.update(:time_out => Time.now, :mentor => mentor)
        end
        halt(200, sms_response(["All students signed out."]))
      end

      # Next, check for multiple IDs in the message.
      ids = params[:Body].split(" ")
      messages = ids.map do |id|
        # Retrieve the student record using the body of the message.
        student = Student.get_by_id(id)
        if student.nil?
          "Error: No matching student."
        else
          # Find the open lab session and sign it out.
          lab_session = student.lab_sessions.select { |session| session.time_out.nil? }.first
          if lab_session.nil?
            "Error: #{student.first_name} #{student.last_name} is not signed in."
          else
            lab_session.update(:time_out => Time.now, :mentor => mentor)
            "#{student.first_name} #{student.last_name} signed out after " +
                "#{lab_session.duration_hours.round(1)} hours."
          end
        end
      end
      halt(200, sms_response(messages))
    end

    get "/reindex_students" do
      unless @user.has_permission?("HOURS_EDIT")
        halt(400, "Need to be an administrator.")
      end

      students = CheesyCommon::Auth.find_users_with_permission("HOURS_SIGN_IN")
      Student.truncate
      students.each do |student|
        Student.create(:id => student.bcp_id, :first_name => student.name[1], :last_name => student.name[0])
      end
      "Successfully imported #{Student.all.size} students."
    end

    get "/csv_report" do
      halt(403, "Insufficient permissions.") unless @user.has_permission?("HOURS_VIEW_REPORT")
      content_type "text/csv"

      rows = []
      rows << ["Last Name", "First Name", "Student ID", "Project Hours"].join(",")
      Student.order_by(:last_name).each do |student|
        rows << [student.last_name, student.first_name, student.id, student.project_hours].join(",")
      end
      rows.join("\n")
    end

    get "/strike_report" do
      halt(403, "Insufficient permissions.") unless @user.has_permission?("HOURS_VIEW_REPORT")

      @weeks = []
      start_time = Time.parse("2016-01-10 00:00:00 PST")
      begin
        week = { :start => start_time }
        start_time += 86400 * 7
        week[:end] = start_time
        @weeks << week
      end while start_time < Time.now
      @min_hours = 5

      erb :strike_report
    end

    def sms_response(messages)
      <<-END
        <Response>
          <Sms>#{messages.join("</Sms><Sms>")}</Sms>
        </Response>
      END
    end

    # RFID tag management.
    set :sockets, []
    @@current_rfid_mentors = []
    @@current_rfid_students = []
    @@tags = Hash.new

    get "/tag_ws" do
      if !request.websocket?
        @signed_in_sessions = LabSession.where(:time_out => nil)
        erb :index
      end

      request.websocket do |ws|
        ws.onopen do
          ws.send({ :status => "Connection Opened" }.to_json)
          @@tags.each do |tag|
            send_ws_msg(:user => tag[1][:user], :state => "in", :tag => tag[1][:tag_id])
          end
          settings.sockets << ws
        end

        ws.onclose do
          ws.send({ :status => "Connection Closed" }.to_json)
          settings.sockets.delete(ws)
        end
      end
    end

    get "/tag/events/in/:id" do
      user = get_user_by_tag(params[:id])
      if user.nil?
        @@tags[params[:id].to_s] = { :type => :unassigned, :tag_id => params[:id] }
      elsif user[:type] == :student
        @@tags[params[:id].to_s] = user
        @@current_rfid_students.push(params[:id].to_s)
        student = user[:user]

        if @@current_rfid_mentors.empty?
          # No mentor tag present, must be sign in.
          unless LabSession.where(:student_id => student.id, :time_out => nil).empty?
            send_ws_msg(:signin => "Error: #{student.first_name} is already signed in.")
          else
            #check for debouncing: allow sign in only 1 minute after sign out
            if (((Time.now - student.lab_sessions.last.time_out)/60) > 1)
              student.add_lab_session(:time_in => Time.now)
              send_ws_msg(:signin => "Signed in #{student.first_name} #{student.last_name}!")
            end
            
          end
        else
          #mentor present, must be sign out
          lab_session = student.lab_sessions.select { |session| session.time_out.nil? }.first
          if lab_session.nil?
            send_ws_msg(:signin => "Error: #{student.first_name} #{student.last_name} is not signed in.")
          else
            mentor = Mentor[Tag.first(:tag_id => @@current_rfid_mentors[0]).mentor_id]
            lab_session.update(:time_out => Time.now, :mentor_id => mentor.id)
            send_ws_msg(:signin => "#{student.first_name} #{student.last_name} signed out after " +
                "#{lab_session.duration_hours.round(1)} hours by #{mentor.first_name} #{mentor.last_name}")
          end
        end
      elsif user[:type] == :mentor
        mentor = user[:user]
        @@tags[params[:id].to_s] = user
        @@current_rfid_mentors.push(params[:id].to_s)
      end

      send_ws_msg(:user => user, :state => "in", :tag => params[:id])
    end

    get "/tag/events/out/:id" do
      tag = Tag.first(:tag_id => params[:id])
      @@tags.delete(params[:id])

      #cache any error for halting after the websocket sends it's message
      error = nil
      if tag.nil?
        error = "No such tag."
      elsif !tag.student_id.nil?
        @@current_rfid_students.delete(params[:id].to_s)
      elsif !tag.mentor_id.nil?
        @@current_rfid_mentors.delete(params[:id].to_s)
      else
        error = "Tag does not reference a student or mentor."
      end

      #Needs to execute for wizard to work
      send_ws_msg(:user => get_user_by_tag(params[:id]), :state => "out", :tag => params[:id])

      #Now check for error
      halt(400, error) unless (error == nil)
    end

    get "/tag/manage" do
      halt(403, "Need to be an administrator.") unless @user.has_permission?("HOURS_MANAGE_TAGS")
      erb :tag_manage_wizard
    end

    get "/tag/manage/assign" do
      halt(403, "Need to be an administrator.") unless @user.has_permission?("HOURS_MANAGE_TAGS")

      tag = Tag.first(:tag_id => params["tag"])
      if tag.nil?
        if params["mode"] == "student"
          Tag.insert(:student_id => params["id"], :tag_id => params["tag"])
        elsif params["mode"] == "mentor"
          Tag.insert(:mentor_id => params["id"], :tag_id => params["tag"])
        else
          halt(400, "Parameter 'mode' is missing.")
        end
      else 
        if params["mode"] == "student"
          tag.student_id = params["id"].to_i
          tag.mentor_id = nil
        elsif params["mode"] == "mentor"
          tag.mentor_id = params["id"].to_i
          tag.student_id = nil
        else
          halt(400, "Parameter 'mode' is missing.")
        end
        tag.save
      end
    end

    get "/tag/live" do
      erb :live_tag_view
    end

    def send_ws_msg(msg)
      EM.next_tick { settings.sockets.each { |s| s.send(msg.to_json) } }
    end

    def get_user_by_tag(tag_id)
      tag = Tag.first(:tag_id => tag_id)
      return nil if tag.nil?

      if !tag.student_id.nil?
        student = Student[tag.student_id]
        return { :type => :student, :user => student, :name => "#{student.first_name} #{student.last_name}", :tag_id => tag.id }
      elsif !tag.mentor_id.nil?
        mentor = Mentor[tag.mentor_id]
        return { :type => :mentor, :user => mentor, :name => "#{mentor.first_name} #{mentor.last_name}", :tag_id => tag.id }
      end

      raise "Tag does not reference a student or mentor."
    end
  end
end