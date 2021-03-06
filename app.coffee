# Application variables
# ----------------------------------------------------------------------------

express = require('express')
app = express.createServer()
app.set 'views', __dirname + '/views'
app.use(express.static(__dirname + '/public'))
redis = require 'redis'
client = redis.createClient()
_ = require 'underscore'

# User-defined variables
# ----------------------------------------------------------------------------

user_vars = {}
user_vars.max_lookback_mins = 10

client.select 3

# Utility functions
# ----------------------------------------------------------------------------

makeKey = (foo...) ->
  args = Array.prototype.slice.call arguments
  args.join ':'

getMinute = (timestamp) ->
  # returns int between 0->59
  seconds_past_hour =  timestamp % 3600
  which_minute = seconds_past_hour / 60
  Math.floor which_minute

getHour = (timestamp) ->
  # returns int between 0->23
  seconds_past_day =  timestamp % 86400
  which_hour = seconds_past_day / 3600
  Math.floor which_hour

getClosestMinute = (timestamp) ->
  # returns the timestamp of the most recent minute
  60 * Math.floor (timestamp / 60)

getClosestHour = (timestamp) ->
  # returns the timestamp of the most recent hour
  3600 * (Math.floor (timestamp / 3600))

getClosestDay = (timestamp) ->
  # returns the timestamp of the most recent day
  86400 * (Math.floor(timestamp / 86400))

# Heavy lifters
# ----------------------------------------------------------------------------

markMinuteAsWorked = (uid, timestamp, include_lookback, cb) ->

  # Mark the minute property of the corresponding hour as worked
  #
  # If include_lookback is true, older minutes will also be marked
  # as true to compensate for the user not hitting the save button
  # every single minute.

  hour = getClosestHour timestamp
  minute = getMinute timestamp

  key = makeKey 'uid', uid, 'hour', hour
  #console.log 'setting key', key, 'and minute', minute

  client.hset key, minute, 1, (err, result) ->
    if err then return cb err

    if not include_lookback
      return cb null
    else
      async_cnt = user_vars.max_lookback_mins
      for i in [user_vars.max_lookback_mins..1]
        new_timestamp = timestamp - (i * 60)
        hour = getClosestHour new_timestamp
        minute = getMinute new_timestamp
        key = makeKey 'uid', uid, 'hour', hour

        # If any minute in the previous ten was worked on, then
        # mark the minutes between now and then as worked on also.

        #console.log 'checking if exists', key, minute
        fn = (_i_copy, _minute) -> client.hexists key, _minute, (err, result) ->
          if err then return cb err
          async_cnt -= 1
          if result
            for j in [_i_copy..1]
              a_timestamp = timestamp - (j * 60)
              markMinuteAsWorked uid, a_timestamp, false, (err, result) ->
                if err then return cb err
          if async_cnt is 0
            return cb null
        fn i, minute

getMinutesWorked = (uid, timestamp, cb) ->
  closest_hour = getClosestHour timestamp
  key = makeKey 'uid', uid, 'hour', closest_hour
  client.hgetall key, (err, result) ->
    if err then return cb err
    tmp = (i for i of result)
    total = tmp.length
    return cb null, result, total

getDayNames = (start_timestamp, days) ->
  result = []
  for i in [0..days]
    timestamp = start_timestamp - (86400 * i)
    result.push getDayName timestamp
  result

getDayName = (timestamp) ->
  ms_timestamp = timestamp * 1000
  d = new Date(ms_timestamp);
  month = [
    'january',
    'february',
    'march',
    'april',
    'may',
    'june',
    'july',
    'august',
    'september',
    'october',
    'november',
    'december',
  ][d.getMonth()]
  day = d.getDate()
  month = month[0].toUpperCase() + month.slice 1
  return month + ' ' + day

# Web Hooks
# ----------------------------------------------------------------------------

app.get '/track/:uid/:days?', (req, res) ->
  uid = req.params.uid
  now = (new Date()).getTime() / 1000
  days = [0..req.params.days or 10]
  hours = [0..23]
  one_hour = 3600
  one_day = one_hour * 24
  async_cnt = days.length * hours.length
  closest_day = getClosestDay now
  num_hour = getHour now
  timezone_offset = 5 # America/New_York
  show_day_zero = num_hour - timezone_offset >= 0
  output = {}
  cumulative_total = 0

  vars = {
    result: {}
    uid: uid
    title: 'Code Timing Tool'
    minutes: [0..59]
    day_names: getDayNames closest_day, days.length
    hours: hours
  }

  for day in days
    output[day] = {}
    output[day].total = 0
    for hour in hours
      output[day][hour] = {}

  for day, index in days
    if index is days.slice(-1)
      continue
    for hour in hours
      fn = (which_day, which_hour) ->

        # 18 UTC -> 13 EST
        # 3 UTC -> 22 EST one day later
        if which_hour - timezone_offset >= 0
          which_hour_after_offset = which_hour - timezone_offset
          which_day_after_offset = which_day
        else
          which_hour_after_offset = which_hour - timezone_offset + 24
          which_day_after_offset = which_day + 1

        timestamp = closest_day - (one_day * which_day) + (one_hour * which_hour)
        getMinutesWorked uid, timestamp, (err, result, total) ->
          if err then return res.send err

          if which_day_after_offset isnt days.slice(-1)[0] + 1
            output[which_day_after_offset][which_hour_after_offset].total = total
            output[which_day_after_offset][which_hour_after_offset].minutes = result
            output[which_day_after_offset].total += total
            cumulative_total += total

          async_cnt -= 1
          if async_cnt is 0
            if not show_day_zero
              console.log 'not showing day zero'

              # Shift everything back one day
              for key, value of output
                output[key - 1] = value

              delete output[-1]
              delete output[_.keys(output).length - 1]

            vars.result = output
            vars.cumulative_total = cumulative_total
            vars.num_days = days.length
            res.render 'index.jade', vars
            return
      fn day, hour

app.get '/save-event/:uid/:timestamp', (req, res) ->
  uid = req.params.uid
  timestamp = req.params.timestamp

  markMinuteAsWorked uid, timestamp, true, (err, result) ->
    if err then return cb err
    res.send 'ok'

# Exports for testing
# ----------------------------------------------------------------------------

exports.getDayName = getDayName

# Listen on port 3000 for incoming connections
# ----------------------------------------------------------------------------

app.listen 3000
