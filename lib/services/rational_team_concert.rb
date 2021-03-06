class Service::RationalTeamConcert < Service
	string   :server_url, :username, :project_area_uuid
	password :password
	boolean :basic_authentication
	white_list :server_url, :username, :basic_authentication

	def receive_push
		checkSettings
		prepare
		authenticate
		commit_changes
	end

	def checkSettings
		raise_config_error "Server Url url not set" if data['server_url'].blank?
		raise_config_error "username not set" if data['username'].blank?
		raise_config_error "password not set" if data['password'].blank?
		raise_config_error "Project Area UUID is not set" if data['project_area_uuid'].blank?
	end

	def prepare
		http.headers['X-com-ibm-team-userid']= data['username']
	end

	def authenticate 
		if data['basic_authentication']
			http.basic_auth data['username'], data['password']
		else
			form_based_authentification
		end
	end

	def form_based_authentification
		res= http_get '%s/authenticated/identity' % data['server_url']
		if not 'authrequired'.eql? res.headers['X-com-ibm-team-repository-web-auth-msg']
			raise_config_error "Invalid authentication url. The response did not include a X-com-ibm-team-repository-web-auth-msg header"
		end
		http.headers['Cookie']= res.headers['set-cookie']
		http.headers['Content-Type']= 'application/x-www-form-urlencoded'

		res= http_post '%s/authenticated/j_security_check' % data['server_url'], 
					   Faraday::Utils.build_nested_query(http.params.merge(:j_username => data['username'], :j_password => data['password'])) 

		if 'authrequired'.eql? res.headers['X-com-ibm-team-repository-web-auth-msg']
			raise_config_error "Invalid Username or Password"
		end

		http.headers['Content-Type']= ''
		res= http_get '%s/authenticated/identity' % data['server_url']
		http.headers['Cookie']= res.headers['set-cookie']
	end

	def commit_changes
		http.headers['Content-Type']= 'application/json'
		http.headers['oslc-core-version']= '2.0'
		http.headers['accept']= 'application/json'
		
		payload['commits'].each do |commit|
			next if commit['message'] =~ /^x / 
			commit['message'].match(/\[(#?(\d+)|[a-zA-Z0-9]+)[^\]]*\]/)
			next unless $1

			comment_body= generate_comment_body commit
			work_item= $2 ? get_work_item($2) : new_work_item(commit, $1)
			post_comment work_item, comment_body
		end
	end

	def generate_comment_body (commit)

		comment_body= "[Message] #{commit['message']}<br/>" +
					  "[Author] #{commit['author']['name']}(#{commit['author']['email']})<br/>" +
				  	  "[Url] #{commit['url']}<br/>"

		comment_body= comment_body + "[Modified]<br/>#{commit['modified'].join('<br/>')}<br/>" if commit['modified'].length > 0
		comment_body= comment_body + "[Added]<br/>#{commit['added'].join('<br/>')}<br/>" if commit['added'].length > 0
		comment_body= comment_body + "[Removed]<br/>#{commit['removed'].join('<br/>')}<br/>" if commit['removed'].length > 0
		return comment_body
	end

	def get_work_item (work_item_number)
		res= http_get "%s/resource/itemName/com.ibm.team.workitem.WorkItem/%s?oslc.properties=oslc:discussedBy" % [ data['server_url'], work_item_number ]  
		return res.body
	end

	def new_work_item (commit, work_item_type)
		url= "%s/oslc/contexts/%s/workitems/%s" % [data['server_url'], data['project_area_uuid'], work_item_type]
		work_item= { 'dcterms:title' => commit['message']}
		res= http_post url, generate_json(work_item)
		raise_config_error "Work item was not created. Make sure that its possible to create work items with no additional required fields" unless res.status == 201
		return res.body
	end

	def post_comment(work_item, comment_body)
		comment_url= get_comment_url work_item
		comment= { 'dcterms:description' => comment_body }
		res= http_post comment_url, generate_json(comment)
		raise_config_error "Not possible to add comments with the current setup" unless res.status == 201
	end

	def get_comment_url (work_item) 
		answer= JSON.parse(work_item)
		discussedBy= answer['oslc:discussedBy']
		raise_config_error "Invalid OSLC response. Expected to receive oslc:discussedBy in the response" unless discussedBy
		return "#{discussedBy['rdf:resource']}/oslc:comment"
	end
end
