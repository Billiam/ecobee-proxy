require 'rubygems'
require 'bundler/setup'
require 'dotenv/load'
require 'httparty'
require 'yaml'
require 'logger'

CONFIG_PATH = File.join(__dir__, 'config.yml')

class BaseClient
  include HTTParty
  default_timeout 5
  
  def with_timeout
    begin
      yield
    rescue Net::OpenTimeout, Net::ReadTimeout
      {}
    end
  end
end

class Ecobee < BaseClient
  base_uri 'https://api.ecobee.com'

  def initialize(api_key, refresh_token, sensor_id, config_path)
    @api_key = api_key
    @refresh_token = refresh_token
    @sensor_id = sensor_id
    @config_path = config_path
  end

  def access_token
    config = begin
       YAML.load_file(@config_path)
    rescue Errno::ENOENT
      {}
    end
    
    if config[:access_token] && config[:expiration] > Time.now.to_i
      return config[:access_token]
    end

    access_token, expiration = fetch_access_token
    if access_token && expiration
      File.write(@config_path, YAML.dump({access_token: access_token, expiration: expiration}, indentation: 2))
      return access_token
    end
    raise "Could not find access token"
  end
  
  def fetch_access_token
    with_timeout do
      result = self.class.post('/token',
        query: {
          'grant_type' => 'refresh_token',
	  'refresh_token' => @refresh_token,
	  'client_id' => @api_key
        }
      )

      [result['access_token'], result['expires_in'] + Time.now.to_i]
    end
  end


  def fetch_sensor
    with_timeout do
      token = self.access_token
      result = self.class.get('/1/thermostat',
        query: {
	  'format' => 'json',
	  'body' => {
	    'selection' => {
	      'selectionType' => 'registered',
	      'selectionMatch' => '',
	      'includeSensors' => true
	    }
	  }.to_json
	},
	headers: {
          'Content-Type' => 'application/json;charset=UTF-8',
	  'Authorization' => "Bearer #{token}"
	}
      )
      # TODO: Return one or more sensors
      # Select different target thermostat
      sensors = result.parsed_response.dig('thermostatList', 0, 'remoteSensors') || []
      sensor = sensors.find do |sensor|
        sensor['id'] == @sensor_id
      end
      return unless sensor
      sensor['capability'].map do |capability|
        type = capability['type'].to_sym
        [
          type, 
          type == :temperature ? capability['value'].to_i / 10.0 : capability['value']
        ]
      end.to_h
    end
  end
end

class Receiver < BaseClient
  def initialize(host)
    @host = host
  end

  def set_temp(temp)
    with_timeout do
      r=self.class.post(
        "#{@host}/temp.json",
        body: {
         'temp' => temp.to_i
        }.to_json,
        headers: {
          'Content-Type' => 'application/json'
        }
      )
    end
  end
end

client = Ecobee.new(ENV['ECOBEE_API_KEY'], ENV['ECOBEE_REFRESH_TOKEN'], ENV['ECOBEE_SENSOR_ID'], CONFIG_PATH)
sensor = client.fetch_sensor
if sensor
  receiver = Receiver.new(ENV['RECEIVER_HOST'])
  result = receiver.set_temp(sensor[:temperature])
end
