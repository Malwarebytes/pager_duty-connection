#!/usr/bin/env ruby

require 'pry'
require 'dotenv'
Dotenv.load ".env.development", '.env'

token = ENV['PAGERDUTY_TOKEN'] || raise("Missing ENV['PAGERDUTY_TOKEN'], add to .env.development")

require 'pager_duty/connection'
$pagerduty = PagerDuty::Connection.new(token)

# http://developer.pagerduty.com/documentation/rest/users/list
response = $pagerduty.get('users')
response.users.each do |user|
  puts "#{user.name}: #{user.email}"
end
