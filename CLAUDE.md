WoolyTube is a lightweight android app that uses yt-dlp to download videos and audio, organize it into playlists, automatically keeps them up to date and provides media playback functionality. The app is client side only, no server, everything runs on the mobile device.

## downloader

This is the module responsible for actually downloading things, running yt-dlp on device as well as ffmpeg since it is required for yt-dlp.

## frontend

Simple Flutter wrapper for the downloader. Minimal, modern design. The color scheme is dark grey background, white text, blue and light grey toggles and buttons. Very minimal, simple look. Thumbnails are central and should be prioritized in terms of screen space versus text.

## Features

The app has a front page that lists all of the users playlists, together with the thumbnail and name of the playlist as well as the last time it was updated. The playlists have a settings button and an update button attached to them. Clicking the update button will prompt the downloader to download any videos so far not downloaded. The settings button will open a settings page which has the name of the playlist at the top and includes settings such as auto update toggle, audio only toggle, include thumbnails toggle, etc. At the top right corner of the front page there is a plus button that when clicked will take the user to the add new playlist page. On the add new playlist page the user must provide a URL and can also set the settings of the playlist, same as on the settings page. By default every option should be toggled to on.
Once a playlist is added it should appear on the front page and start downloading automatically, the status of this should be clearly visible with a progress bar and a count for what number the playlist has been downloaded to. There should also be a notification which appears when downloading.
Downloaded files should be saved in clearly labeled and freely accesible folders, so that even if the user deletes the app their files stay on the device and can be manually backed up to other devices and so on. Filenames should start with leading zeros and the index of the video in the original playlist.
Auto update should by default be once per day but the frequency can be changed in the settings, minimum 1 hour, maximum 1 week.
Playback of downloaded content can also be handled by the app, when clicking a playlist on the front page the user is taken to a playlist page, where videos or audio is listed with their thumbnails and indexes. The playlist page includes a shuffle button, an autoplay toggle and a search bar. When clicking on a piece of content playback should start there. If the content is a video file by default it should be played as video, but there should be an option to play as audio. If the user moves elsewhere within the app, playback should still continue. Same if the user exits the app. For video playback there should be a miniplayer, for audio just background playback by default.

## Potential future features

These features are not important for now, but if we can make decisions now that will make it easier to implement them later we will try to prioritize implementations that will help us achieve these goals.

- Automatically update the app if there is a new release of yt-dlp on GitHub
- Automatically check for unavailable videos, and try to find them online (for example with https://quiteaplaylist.com/ ) potentially provide alternatives that are currently available online
- Update a given playlist in app and have it be automatically updated on YouTube (like reordering songs for example)
- IOS support