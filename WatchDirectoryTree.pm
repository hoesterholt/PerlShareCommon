package PerlShareCommon::WatchDirectoryTree;
use strict;
use PerlShareCommon::Log;
use IO::Select;
use Fcntl;

sub new() {
	my $class=shift;
	my $directory=shift;
	my $obj={};
	bless $obj,$class;
	$obj->{dir}=$directory;
	
	log_info("Watching directory $directory");
	  
	$obj->{os}=$^O;
	if ($obj->{os} eq "darwin") {
	  log_debug("FSEvents for mac OS X");
	  require IO::Select;
	  require Fcntl;
		require Mac::FSEvents;
		my $fs=Mac::FSEvents->new( 
			{
				path 		=> $directory,
				latency 	=> 2,
			}
		);
		my $fh=$fs->watch();
		$obj->{fh}=$fh;
		$obj->{fs}=$fs;
	} elsif ($obj->{os}=~/^MSWin/) {
	  require Win32::ChangeNotify;
	  my $notify = Win32::ChangeNotify->new($directory, 1, "ATTRIBUTES|DIR_NAME|FILE_NAME|LAST_WRITE|SIZE");
	  $obj->{notify}=$notify;
	} else {
	  log_debug("inotifywait for linux");
		my $pid = open my $fh,"inotifywait --exclude '[.]unison|[.]count' -r -m -e close_write -e moved_to -e moved_from -e create -e delete --format \"dir=%w\" '$directory' 2>&1 |";
		my $of = select($fh); $| = 1;select($of);
		my $flags = '';
		fcntl($fh, F_GETFL, $flags) or die "Couldn't get flags for HANDLE : $!\n";
		$flags |= O_NONBLOCK;
		fcntl($fh, F_SETFL, $flags) or die "Couldn't set flags for HANDLE: $!\n";
		$obj->{fh} = $fh;
		$obj->{pid} = $pid;
	}
	
	log_info("Created watcher");
	
	return $obj;
}

sub kill_watcher() {
  my $self = shift;
  if (not(defined($self->{killed}))) {
    log_debug("killing watcher");

    my $fh = $self->{fh};
    if (defined($self->{notify})) {  # MSWin
      log_debug("closing notify connection");
      $self->{notify}->close();
    } else { # Darwin, Linux
      
      # Make sure inotifywait ends.
      my $dir = $self->{dir};
      
      my $file = "$dir/___kill_watcher___";
      log_debug("Creating work for inotifywait (file $file)");
      system("touch \"$file\"");
      
      #open my $fout, ">$file";
      #print $fout "HI!\n";
      #close($fout);
      
      my $pid = $self->{pid};
      if (defined($pid)) { 
        log_debug("killing inotifywait/fsevent (pid = $pid)");
        kill 15, $pid;
      }

      log_debug("closing inotifywait/fsevent connection");
      close($fh);
      
      log_debug("cleaning up file $file");
      unlink($file);
      
      log_debug("inotifywait/fsevent connection closed");
    }

    $self->{pid} = undef;
    $self->{fh} = undef;
    $self->{notify} = undef;
    $self->{killed} = 1;
  }
}

sub DESTROY() {
  my $self = shift;
  log_debug("destroying WatchDirectoryTree");
  $self->kill_watcher();
}

sub get_directory_changes() {
	my $self=shift;
	my @dirs=();
	my $dir=$self->{dir};
	
	if ($self->{os} eq "darwin") { # OS X
		my $fh=$self->{fh};
		my $fs=$self->{fs};
		my $sel = IO::Select->new($fh);
  		while ( $sel->can_read(0) ) {
      		my @events = $fs->read_events();
      		for my $event ( @events ) {
      			my $p=$event->path();
      			$p=~s/[\/\\]*$//;
      			push @dirs,$p;
      		}
  		}
  		if (scalar(@dirs)==0) {
  			return undef;
  		} else {
  			return \@dirs;
  		}
	} elsif ($self->{os} =~ /^MSWin/) {
	  my $chg = $self->{notify}->wait(100); # Wait for max 0.1 second for changes
	  if ($chg != 0) {
	    while ($chg != 0) {
	      $self->{notify}->reset();
	      $chg = $self->{notify}->wait(100); # Wait for max 0.1 second for changes
	    }
	    my @dirs;
	    push @dirs, "win32: directories or files have changed";
	    return \@dirs;
	  } else {
	    $self->{notify}->reset();
	    return undef;
	  }
	} else { # linux
		my $fh=$self->{fh};
		my $sel=IO::Select->new($fh);
		my %events;
		my $i=0;
		my $buf="";
		if ($sel->can_read(0)) {
		  log_info("CanRead");
		  my $did_read_any = 1;
			while($sel->can_read(0.1)  && $did_read_any) {
				my $d;
				log_warn("Potential 100".'%'." CPU Risk here!");
				my $l;
				$did_read_any = 0;
				while (my $l=sysread($fh,$d,1024)) {
				  log_warn("l = $l");
				  $did_read_any = 1;
					$buf.=$d;
				}
				log_warn("l = $l");
			}
			log_info("Done reading");
			my @lines=split /\n/,$buf;
			foreach my $line (@lines) {
				log_debug("line($dir)=$line");
				if ($line=~/^dir=/) {
					my ($key,$path)=split(/=/,$line);
					$path=~s/[\/\\]+$//;
					$events{$path}=$i;
					log_debug("got directory $path ($i)");
					$i+=1;
				}
			}
		}
		my @dirs=sort { $events{$a} cmp $events{$b} } (keys %events);
		if (scalar(@dirs)==0) {
			return undef;
		} else {
			return \@dirs;
		}
	}
}


1;
