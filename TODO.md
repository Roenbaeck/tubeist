# Yellow fading text
The yellow 'fade' messages should follow up top if the system metrics have been moved to the top, and display just below it. 

# Additions in modified-files
There are additions in the modified-files folder, which contains copies of swift files from an external coder with no access to GitHub. He has added a few more settings for YouTube. I need you to assess if these are safe to add, and help me add them. Also check if he has made any other improvements in those files.

# Clickable YouTube icon
I think it would be good if the YouTube icon was clickable once a stream has started, and this triggers a refresh of the stream status. We need to add a cooldown, so it's not spammable though. Similar to the refresh button in the settings. 

# Add Stream-ID header 
Align with this commit https://github.com/Roenbaeck/hls-relay/commit/e154e87f01a36ff575b49a46fa93b86c9ef0c0fa in the HLS server. We need to send Stream-ID header along with the segments to the server, consisting of a timestamp on the form YYYYMMDD_HHMMSS. This timestamp is the time when the "record" button was pressed and it should accompany every segment sent that belongs to the same stream, always refering to the same timestamp of that button press. Once a stream is stopped and a new stream started, a new Stream-ID is created. 
