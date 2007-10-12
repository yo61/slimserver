package Slim::Plugin::Pandora::ProtocolHandler;

# $Id: ProtocolHandler.pm 11678 2007-03-27 14:39:22Z andy $

# Handler for pandora:// URLs

use strict;
use base qw(Slim::Player::Protocols::HTTP);

use JSON::XS qw(from_json);

use Slim::Player::Playlist;
use Slim::Utils::Misc;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.pandora',
	'defaultLevel' => $ENV{PANDORA_DEV} ? 'DEBUG' : 'WARN',
	'description'  => 'PLUGIN_PANDORA_MODULE_NAME',
});

# default artwork URL if an album has no art
my $defaultArtURL = 'http://www.pandora.com/images/no_album_art.jpg';

# To support remote streaming (synced players, slimp3/SB1), we need to subclass Protocols::HTTP
sub new {
	my $class  = shift;
	my $args   = shift;

	my $client = $args->{client};
	my $url    = $args->{url};
	
	my $track  = $client->pluginData('currentTrack') || {};
	
	$log->debug( 'Remote streaming Pandora track: ' . $track->{audioUrl} );

	return unless $track->{audioUrl};

	my $sock = $class->SUPER::new( {
		url     => $track->{audioUrl},
		client  => $client,
		bitrate => 128_000,
	} ) || return;
	
	${*$sock}{contentType} = 'audio/mpeg';

	# XXX: Time counter is not right, it starts from 0:00 as soon as next track 
	# begins streaming (slimp3/SB1 only)
	
	return $sock;
}

sub getFormatForURL () { 'mp3' }

sub isAudioURL () { 1 }

# Don't allow looping if the tracks are short
sub shouldLoop () { 0 }

sub handleError {
    my ( $error, $client ) = @_;

	if ( $client ) {
		$client->unblock;
		
		Slim::Buttons::Common::pushModeLeft( $client, 'INPUT.Choice', {
			header  => '{PLUGIN_PANDORA_ERROR}',
			listRef => [ $error ],
		} );
		
		if ( $ENV{SLIM_SERVICE} ) {
		    logError( $client, $error );
		}
	}
}

# Whether or not to display buffering info while a track is loading
sub showBuffering {
	my ( $class, $client, $url ) = @_;
	
	my $showBuffering = $client->pluginData('showBuffering');
	
	return ( defined $showBuffering ) ? $showBuffering : 1;
}

# Perform processing during play/add, before actual playback begins
sub onCommand {
	my ( $class, $client, $cmd, $url, $callback ) = @_;
	
	# Only handle 'play'
	if ( $cmd eq 'play' ) {
		# Display buffering info on loading the next track
		$client->pluginData( showBuffering => 1 );
		
		my ($stationId) = $url =~ m{^pandora://([^.]+)\.mp3};
		
		# If the user was playing a different Pandora station, report a stationChange event
		my $prevTrack = $client->pluginData('prevTrack') || $client->pluginData('currentTrack');
		if ( $prevTrack && $prevTrack->{stationToken} ne $stationId ) {
			my $snURL = Slim::Networking::SqueezeNetwork->url(
				  '/api/pandora/playback/stationChange?stationId=' . $prevTrack->{stationToken} 
				. '&trackId=' . $prevTrack->{trackToken}
			);

			my $http = Slim::Networking::SqueezeNetwork->new(
				sub {},
				sub {},
				{
					client  => $client,
					timeout => 35,
				},
			);

			$log->debug('Reporting station change to SqueezeNetwork');
			$http->get( $snURL );
		}
		
		getNextTrack( $client, {
			stationId => $stationId,
			callback  => $callback,
		} );
		
		return;
	}
	
	return $callback->();
}

sub getNextTrack {
	my ( $client, $params ) = @_;
	
	my $stationId = $params->{stationId};
	
	# Talk to SN and get the next track to play
	my $trackURL = Slim::Networking::SqueezeNetwork->url(
		"/api/pandora/playback/getNextTrack?stationId=$stationId"
	);
	
	my $http = Slim::Networking::SqueezeNetwork->new(
		\&gotNextTrack,
		\&gotNextTrackError,
		{
			client  => $client,
			params  => $params,
			timeout => 35,
		},
	);
	
	$log->debug("Getting next track from SqueezeNetwork");
	
	$http->get( $trackURL );
}

sub gotNextTrack {
	my $http   = shift;
	my $client = $http->params->{client};
	my $params = $http->params->{params};
	
	my $track = eval { from_json( $http->content ) };
	
	if ( $@ || $track->{error} ) {
		# We didn't get the next track to play
		if ( $log->is_warn ) {
			$log->warn( 'Pandora error getting next track: ' . ( $@ || $track->{error} ) );
		}
		
		my $url = Slim::Player::Playlist::url($client);

		setCurrentTitle( $client, $url, $track->{error} || $client->string('PLUGIN_PANDORA_NO_TRACKS') );
		
		$client->update();

		Slim::Player::Source::playmode( $client, 'stop' );
	
		return;
	}
	
	if ( $log->is_debug ) {
		$log->debug( 'Got Pandora track: ' . Data::Dump::dump($track) );
	}
	
	# Watch for playlist commands
	Slim::Control::Request::subscribe( 
		\&playlistCallback, 
		[['playlist'], ['repeat', 'newsong']],
	);
	
	# Force repeating
	Slim::Player::Playlist::repeat( $client, 2 );
	
	# Save the previous track's metadata, in case the user wants track info
	# after the next track begins buffering
	$client->pluginData( prevTrack => $client->pluginData('currentTrack') );
	
	# Save the time difference between SN and SqueezeCenter
	$track->{timediff} = $track->{now} - time();
	
	# Save metadata for this track, and save the previous track
	$client->pluginData( currentTrack => $track );
	
	my $cb = $params->{callback};
	$cb->();
}

sub gotNextTrackError {
	my $http   = shift;
	my $client = $http->params('client');
	
	handleError( $http->error, $client );
	
	# Make sure we re-enable readNextChunkOk
	$client->readNextChunkOk(1);
}

# Handle normal advances to the next track
sub onDecoderUnderrun {
	my ( $class, $client, $nextURL, $callback ) = @_;
	
	# Special handling needed when synced
	if ( Slim::Player::Sync::isSynced($client) ) {
		if ( !Slim::Player::Sync::isMaster($client) ) {
			# Only the master needs to fetch next track info
			$log->debug('Letting sync master fetch next Pandora track');
			return;
		}
		else {
			# XXX: Source does not call skipahead when synced for some reason
			# Need to restart playback here?
		}
	}

	# Flag that we don't want any buffering messages while loading the next track,
	$client->pluginData( showBuffering => 0 );
	
	# Get next track
	my ($stationId) = $nextURL =~ m{^pandora://([^.]+)\.mp3};
	
	getNextTrack( $client, {
		stationId => $stationId,
		callback  => $callback,
	} );
	
	return;
}

# On skip, load the next track before playback
sub onJump {
    my ( $class, $client, $nextURL, $callback ) = @_;

	# Display buffering info on loading the next track
	# unless we shouldn't (when rating down)
	if ( $client->pluginData('banMode') ) {
		$client->pluginData( showBuffering => 0 );
		$client->pluginData( banMode => 0 );
	}
	else {
		$client->pluginData( showBuffering => 1 );
	}
	
	# Get next track
	my ($stationId) = $nextURL =~ m{^pandora://([^.]+)\.mp3};
	
	getNextTrack( $client, {
		stationId => $stationId,
		callback  => $callback,
	} );
	
	return;
}

sub parseDirectHeaders {
	my $class   = shift;
	my $client  = shift || return;
	my $url     = shift;
	my @headers = @_;
	
	my $bitrate     = 128_000;
	my $contentType = 'mp3';
	
	# Clear previous duration, since we're using the same URL for all tracks
	Slim::Music::Info::setDuration( $url, 0 );
	
	# Grab content-length for progress bar
	my $length;
	foreach my $header (@headers) {
		if ( $header =~ /^Content-Length:\s*(.*)/i ) {
			$length = $1;
			last;
		}
	}
	
	# title, bitrate, metaint, redir, type, length, body
	return (undef, $bitrate, 0, undef, $contentType, $length, undef);
}

# If an audio stream fails, keep playing
sub handleDirectError {
	my ( $class, $client, $url, $response, $status_line ) = @_;
	
	$log->info("Direct stream failed: [$response] $status_line");
	
	$client->showBriefly( {
		line => [ $client->string('PLUGIN_PANDORA_ERROR'), $client->string('PLUGIN_PANDORA_STREAM_FAILED') ]
	},
	{
		block  => 1,
		scroll => 1,
	} );
	
	# Report the audio failure to Pandora
	my ($stationId)  = $url =~ m{^pandora://([^.]+)\.mp3};
	my $currentTrack = $client->pluginData('prevTrack') || $client->pluginData('currentTrack');
	
	my $snURL = Slim::Networking::SqueezeNetwork->url(
		  '/api/pandora/opml/playback?audioError?stationId=' . $stationId 
		. '&trackId=' . $currentTrack->{trackToken}
	);
	
	my $http = Slim::Networking::SqueezeNetwork->new(
		sub {},
		sub {},
		{
			client  => $client,
			timeout => 35,
		},
	);
	
	$http->get( $snURL );
	
	# XXX: Stop after a certain number of errors in a row
	
	$client->execute([ 'playlist', 'play', $url ]);
}

# Check if player is allowed to skip, using canSkip value from SN
sub canSkip {
	my $client = shift;
	
	if ( my $track = $client->pluginData('currentTrack') ) {
		return $track->{canSkip};
	}
	
	return 1;
}	

# Disallow skips after the limit is reached
sub canDoAction {
	my ( $class, $client, $url, $action ) = @_;
	
	if ( $action eq 'stop' && !canSkip($client) ) {
		# Is skip allowed?
		$log->debug("Pandora: Skip limit exceeded, disallowing skip");

		$client->showBriefly( {
			line => [ $client->string('PLUGIN_PANDORA_MODULE_NAME'), $client->string('PLUGIN_PANDORA_SKIPS_EXCEEDED') ]
		},
		{
			scroll => 1,
			block  => 1,
		} );
				
		return 0;
	}
	
	return 1;
}

sub canDirectStream {
	my ( $class, $client, $url ) = @_;
	
	# We need to check with the base class (HTTP) to see if we
	# are synced or if the user has set mp3StreamingMethod
	my $base = $class->SUPER::canDirectStream( $client, $url );
	if ( !$base ) {
		return 0;
	}
	
	my $track = $client->pluginData('currentTrack') || {};
	
	return $track->{audioUrl} || 0;
}

sub playlistCallback {
	my $request = shift;
	my $client  = $request->client();
	my $cmd     = $request->getRequest(0);
	my $p1      = $request->getRequest(1);
	
	return unless defined $client;
	
	# ignore if user is not using Pandora
	my $url = Slim::Player::Playlist::url($client) || return;
	
	return if $url !~ /^pandora/;
	
	$log->debug("Got playlist event: $p1");
	
	# The user has changed the repeat setting.  Pandora requires a repeat
	# setting of '2' (repeat all) to work properly, or it will cause the
	# "stops after every song" bug
	if ( $p1 eq 'repeat' ) {
		$log->debug("User changed repeat setting, forcing back to 2");
		
		Slim::Player::Playlist::repeat( $client, 2 );
		
		if ( $client->playmode =~ /playout/ ) {
			$client->playmode( 'playout-play' );
		}
	}
	elsif ( $p1 eq 'newsong' ) {
		# A new song has started playing.  We use this to change titles
		my $track = $client->pluginData('currentTrack');
		
		my $title 
			= $track->{songName} . ' ' . $client->string('BY') . ' '
			. $track->{artistName} . ' ' . $client->string('FROM') . ' '
			. $track->{albumName};
		
		setCurrentTitle( $client, $url, $title );
		
		# Remove the previous track metadata
		$client->pluginData( prevTrack => 0 );
	}
}

# Override replaygain to always use the supplied gain value
sub trackGain {
	my ( $class, $client, $url ) = @_;
	
	my $currentTrack = $client->pluginData('currentTrack');
	
	my $gain = $currentTrack->{trackGain} || 0;
	
	$log->info("Using replaygain value of $gain for Pandora track");
	
	return $gain;
}

# Track Info menu
sub trackInfo {
	my ( $class, $client, $track ) = @_;
	
	my $url = $track->url;
	
	my $secs = Slim::Music::Info::getDuration($url);

	my ($stationId) = $url =~ m{^pandora://([^.]+)\.mp3};
	
	# Get the current track
	my $currentTrack = $client->pluginData('prevTrack') || $client->pluginData('currentTrack');
	
	# SN URL to fetch track info menu
	my $trackInfoURL = Slim::Networking::SqueezeNetwork->url(
		  '/api/pandora/opml/trackinfo?stationId=' . $stationId 
		. '&trackId=' . $currentTrack->{trackToken}
		. '&secs=' . $secs
	);
	
	# let XMLBrowser handle all our display
	my %params = (
		header   => 'PLUGIN_PANDORA_GETTING_TRACK_DETAILS',
		modeName => 'Pandora Now Playing',
		title    => Slim::Music::Info::getCurrentTitle( $client, $url ),
		url      => $trackInfoURL,
		remember => 0,
		timeout  => 35,
	);

	Slim::Buttons::Common::pushMode( $client, 'xmlbrowser', \%params );
	
	$client->modeParam( 'handledTransition', 1 );
}

# URL used for CLI trackinfo queries
sub trackInfoURL {
	my ( $class, $client, $url ) = @_;
	
	my $secs = Slim::Music::Info::getDuration($url);

	my ($stationId) = $url =~ m{^pandora://([^.]+)\.mp3};
	
	# Get the current track
	my $currentTrack = $client->pluginData('prevTrack') || $client->pluginData('currentTrack');
	
	# SN URL to fetch track info menu
	my $trackInfoURL = Slim::Networking::SqueezeNetwork->url(
		  '/api/pandora/opml/trackinfo?stationId=' . $stationId 
		. '&trackId=' . $currentTrack->{trackToken}
		. '&secs=' . $secs
	);
	
	return $trackInfoURL;
}

sub setCurrentTitle {
	my ( $client, $url, $title ) = @_;
	
	# We can't use the normal getCurrentTitle method because it would cause multiple
	# players playing the same station to get the same titles
	$client->pluginData( currentTitle => $title );
	
	# Call the normal setCurrentTitle method anyway, so it triggers callbacks to
	# update the display
	Slim::Music::Info::setCurrentTitle( $url, $title );
}

sub getCurrentTitle {
	my ( $class, $client, $url ) = @_;
	
	return $client->pluginData('currentTitle');
}

# Metadata for a URL, used by CLI/JSON clients
sub getMetadataFor {
	my ( $class, $client, $url ) = @_;
	
	my $track = $client->pluginData('prevTrack') || $client->pluginData('currentTrack') || return;
	
	return {
		artist      => $track->{artistName},
		album       => $track->{albumName},
		title       => $track->{songName},
		cover       => $track->{albumArtUrl} || $defaultArtURL,
		replay_gain => $track->{trackGain},
		bitrate     => '128k CBR',
		type        => 'MP3 (Pandora)',
		buttons     => {
			# disable REW/Previous button
			rew => 0,

			# replace repeat with Thumbs Up
			repeat  => {
				cls     => 'btn-thumbs-up',
				tooltip => Slim::Utils::Strings::string('PLUGIN_PANDORA_I_LIKE'),
#				icon    => '...path to icon...',
				command => [ 'pandora', 'rate', 1 ],
			},

			# replace shuffle with Thumbs Down
			shuffle => {
				cls     => 'btn-thumbs-down',
				tooltip => Slim::Utils::Strings::string('PLUGIN_PANDORA_I_DONT_LIKE'),
#				icon    => '... path to icon...',
				command => [ 'pandora', 'rate', 0 ],
			},
		}
	};
}

1;
