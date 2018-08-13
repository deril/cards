require "sinatra"
require "sinatra/content_for"
require "sinatra/reloader" if development?
require "pry" if development?
require "redis"
require "bcrypt"
require "rest-client"
require "raven"

Raven.configure do |config|
  config.dsn = 'https://329136ad78ee45cdb3af07820e508dc5:5e52863787084b3b98cbdca70fb43fdc@sentry.io/1260976'
end

use Raven::Rack

REDIRECT_URI = CGI.escape("https://learnaword.net/callback")

enable :sessions
set :session_secret, File.read(ENV["SESSION_SECRET_PATH"])

# TODO: Handle CSRF.

helpers do
  def redis
    @_redis ||= Redis.new(host: ENV["REDIS_HOST"])
  end

  def current_user_id
    redis.hget(:users, session[:uid])
  end

  def require_login
    if current_user_id.nil?
      redirect to("https://learnaword.eu.auth0.com/authorize/?response_type=code&client_id=JlceY3aJuhEB06gtZMdbyKOO0R8fBwMm&redirect_uri=#{REDIRECT_URI}&scope=openid")
    end
  end
end

get "/styles.css" do
  scss :styles
end

get "/cards/new" do
  require_login

  erb :new
end

get "/" do
  require_login

  card_ids = redis.smembers("user:#{current_user_id}:current-cards")

  @cards = card_ids.map do |id|
    card = redis.hgetall("card:#{id}")
    left, middle, right = card["front"].split("*")
    { id: id, left: left, middle: middle, right: right, back: card["back"] }
  end

  erb :index
end

get "/cards" do
  require_login

  card_ids = redis.zrevrange("user:#{current_user_id}:cards", 0, -1)
  current_card_ids = redis.smembers("user:#{current_user_id}:current-cards")

  @cards = card_ids.map do |id|
    card = redis.hgetall("card:#{id}")
    left, middle, right = card["front"].split("*")
    { id: id, left: left, middle: middle, right: right, back: card["back"], current: current_card_ids.include?(id) }
  end

  erb :cards
end

get "/cards/random" do
  require_login

  id = redis.srandmember("user:#{current_user_id}:current-cards")
  redirect to("/cards/#{id}")
end

get "/cards/:id" do
  require_login

  unless redis.zrank("user:#{current_user_id}:cards", params[:id])
    halt "Card not found"
  end

  card = redis.hgetall("card:#{params[:id]}")
  left, middle, right = card["front"].split("*")
  @card = { id: params[:id], left: left, middle: middle, right: right, back: card["back"] }

  erb :card
end

get "/cards/:id/edit" do
  require_login

  unless redis.zrank("user:#{current_user_id}:cards", params[:id])
    halt "Card not found"
  end

  card = redis.hgetall("card:#{params[:id]}")
  _, middle, _ = card["front"].split("*")
  @card = { id: params[:id], front: card["front"], back: card["back"], middle: middle }

  erb :edit
end

patch "/cards/:id" do
  require_login

  unless redis.zrank("user:#{current_user_id}:cards", params[:id])
    halt "Card not found"
  end

  redis.hmset("card:#{params[:id]}", "front", params[:front], "back", params[:back])
  redirect to("/cards/#{params[:id]}")
end

post "/current-cards" do
  require_login

  unless redis.zrank("user:#{current_user_id}:cards", params[:id])
    halt "Card not found"
  end

  redis.sadd("user:#{current_user_id}:current-cards", params[:id])
  redirect to("/cards")
end

delete "/current-cards/:id" do
  require_login

  unless redis.zrank("user:#{current_user_id}:cards", params[:id])
    halt "Card not found"
  end

  redis.srem("user:#{current_user_id}:current-cards", params[:id])
  redirect to("/")
end

post "/cards" do
  require_login

  id = redis.incr(:next_card_id)
  redis.hmset("card:#{id}", "front", params[:front], "back", params[:back])
  redis.zadd("user:#{current_user_id}:cards", Time.now.to_i, id)
  redis.sadd("user:#{current_user_id}:current-cards", id)
  redirect to("/cards")
end

delete "/cards/:id" do
  require_login

  unless redis.zrank("user:#{current_user_id}:cards", params[:id])
    halt "Card not found"
  end

  redis.zrem("user:#{current_user_id}:cards", params[:id])
  redis.srem("user:#{current_user_id}:current-cards", params[:id])
  redis.del("card:#{params[:id]}")
  redirect to("/cards")
end

get "/callback" do
  payload = {
    grant_type: "authorization_code",
    client_id: "JlceY3aJuhEB06gtZMdbyKOO0R8fBwMm",
    client_secret: File.read(ENV["AUTH0_CLIENT_SECRET_PATH"]),
    code: params[:code],
    redirect_uri: REDIRECT_URI
  }

  logger.info(params.inspect)

  # response = RestClient.post("https://learnaword.eu.auth0.com/oauth/token", payload.to_json, "Content-Type" => "application/json")
  # body = JSON.parse(response.body)

  # response = RestClient.get("https://learnaword.eu.auth0.com/userinfo", "Authorization" => "Bearer #{body['access_token']}")
  # body = JSON.parse(response.body)

  # session[:uid] = body["sub"]
  redirect to("/")
end

post "/logout" do
  session[:uid].clear
  redirect to("/")
end
