# Copyright © 2018-2020 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

=head2 OpenQA::Qemu::Proc

Manages the state of a QEMU virtual machine and processes. This is used by
backend/qemu.pm to (re)start qemu processes while tracking what settings have
changed between restarts and generating the necessary qemu command line
parameters.

This class uses an object model which approximates QEMU's device model. The
idea is to allow you to set QEMU parameters in a structured way that can be
updated as QEMU's state changes during execution.

This is not practical (at least in the short term) for all parameters so there
are static parameters which are stored as simple strings and mutable
parameters which are represented as complex objects.

=cut

package OpenQA::Qemu::Proc;
use Mojo::Base -base;

use Data::Dumper;
use File::Basename;
use File::Which;
use File::Spec;
use Mojo::JSON qw(encode_json decode_json);
use Mojo::File 'path';
use OpenQA::Qemu::BlockDevConf;
use OpenQA::Qemu::ControllerConf;
use OpenQA::Qemu::DriveDevice 'QEMU_IMAGE_FORMAT';
use OpenQA::Qemu::SnapshotConf;
use osutils qw(gen_params runcmd run);
use Mojo::IOLoop::ReadWriteProcess 'process';
use Mojo::IOLoop::ReadWriteProcess::Session 'session';

use POSIX ();

use constant STATE_FILE => 'qemu_state.json';

has qemu_bin     => 'qemu-kvm';
has qemu_img_bin => 'qemu-img';
has _process     => sub { process(
        pidfile       => 'qemu.pid',
        separate_err  => 0,
        blocking_stop => 1) };

has _static_params => sub { return []; };
has _mut_params    => sub { return []; };

sub _push_mut { push(@{shift->_mut_params}, shift); }

has controller_conf => sub { return OpenQA::Qemu::ControllerConf->new(); };
has blockdev_conf   => sub { return OpenQA::Qemu::BlockDevConf->new(); };
has snapshot_conf   => sub { return OpenQA::Qemu::SnapshotConf->new(); };

sub new {
    my $self = shift->SUPER::new(@_);

    $self->_push_mut($self->controller_conf);
    $self->_push_mut($self->blockdev_conf);
    $self->_push_mut($self->snapshot_conf);

    return $self;
}

=head3 static_param

Add a plain QEMU parameter, represented as an array of strings. The first item
in the array will have '-' prepended to it.

=cut
sub static_param {
    my $self = shift;

    if (@_ < 2) {
        push(@{$self->_static_params}, '-' . shift);
    }
    else {
        gen_params(@{$self->_static_params}, shift, shift, @_);
    }
}

=head3 configure_controllers

Add SCSI, PCI and USB controllers if necessary. QEMU will automatically create
controllers for simple configurations.

=cut
sub configure_controllers {
    my ($self, $vars) = @_;

    # Setting the HD or CD model to a type of SCSI controller has been
    # deprecated for a long time.
    for my $var (qw(HDDMODEL CDMODEL)) {
        if ($vars->{$var} =~ /virtio-scsi.*/) {
            die "Set $var to scsi-" . lc(substr($var, 0, 1)) . 'd and SCSICONTROLLER to '
              . $vars->{$var};
        }
    }

    if ($vars->{CDMODEL} eq 'scsi-cd' || $vars->{HDDMODEL} eq 'scsi-hd') {
        $vars->{SCSICONTROLLER} ||= "virtio-scsi-pci";
    }

    my $scsi_con = $vars->{SCSICONTROLLER} || 0;
    my $cc       = $self->controller_conf;

    if ($scsi_con) {
        $cc->add_controller($scsi_con, 'scsi0');
        if ($vars->{MULTIPATH}) {
            $cc->add_controller($scsi_con, 'scsi1');
        }
    }

    if ($vars->{ATACONTROLLER}) {
        $cc->add_controller($vars->{ATACONTROLLER}, 'ahci0');
    }

    if ($vars->{USBBOOT}) {
        $cc->add_controller('usb-ehci', 'ehci0');
    }

    return $self;
}

sub get_img_json_field {
    my ($self, $path, $field) = @_;
    my $json = run($self->qemu_img_bin, 'info', '--output=json', $path);
    # We can't check the exit code of qemu-img, because it sometimes returns 1
    # even for a successful command on ppc. Instead we just hide and ignore
    # JSON decode failures and assume the previous command has printed the
    # error string already
    my $map;
    {
        local $SIG{__DIE__} = 'DEFAULT';
        $map = eval { decode_json($json) }
    };
    die "$json\n" if $@;
    die "No $field field in: " . Dumper($map) unless defined $map->{$field};
    return $map->{$field};
}

sub get_img_size {
    my ($self, $path) = @_;
    return $self->get_img_json_field($path, 'virtual-size');
}

sub get_img_format {
    my ($self, $path) = @_;
    return $self->get_img_json_field($path, 'format');
}

=head3 configure_blockdevs

Configure disk drives and their block device backing chains. See BlockDevConf.pm.

=cut
sub configure_blockdevs {
    my ($self, $bootfrom, $basedir, $vars) = @_;
    my $bdc       = $self->blockdev_conf;
    my @scsi_ctrs = $self->controller_conf->get_controllers(qr/scsi/);

    $bdc->basedir($basedir);

    for my $i (1 .. $vars->{NUMDISKS}) {
        my $hdd_model    = $vars->{"HDDMODEL_$i"} // $vars->{HDDMODEL};
        my $backing_file = $vars->{"HDD_$i"};
        my $node_id      = 'hd' . ($i - 1);
        my $hdd_serial   = $vars->{"HDDSERIAL_$i"} || $node_id;
        my $size         = $vars->{"HDDSIZEGB_$i"};
        my $num_queues   = $vars->{"HDDNUMQUEUES_$i"} || -1;
        my $drive;

        $size .= 'G' if defined($size);

        if (defined $backing_file) {
            $backing_file = File::Spec->rel2abs($backing_file);
            # Handle files compressed as *.xz
            my ($name, $path, $ext) = fileparse($backing_file, ".xz");
            if ($ext =~ qr /.xz/) {
                die 'unxz was not found in PATH' unless defined which('unxz');
                bmwqemu::diag("Extracting XZ compressed file");
                runcmd('nice', 'ionice', 'unxz', '-k', '-f', $backing_file);
                $backing_file = $path . $name;
            }
            $size //= $self->get_img_size($backing_file);
            $drive = $bdc->add_existing_drive($node_id, $backing_file, $hdd_model, $size, $num_queues);
        } else {
            $size //= $vars->{HDDSIZEGB} . 'G';
            $drive = $bdc->add_new_drive($node_id, $hdd_model, $size, $num_queues);
        }

        if ($i == 1 && $bootfrom eq 'disk') {
            $drive->bootindex(0);
        }

        $drive->serial($hdd_serial);
        if ($vars->{MULTIPATH}) {
            for my $c (0 .. $vars->{PATHCNT} - 1) {
                $bdc->add_path_to_drive("path$c",
                    $drive,
                    $scsi_ctrs[$c % 2]);
            }
        }
    }

    my $iso = $vars->{ISO};
    if ($iso) {
        $iso = File::Spec->rel2abs($iso);
        my $size = $self->get_img_size($iso);
        if ($vars->{USBBOOT}) {
            $size = $vars->{USBSIZEGB} . 'G' if $vars->{USBSIZEGB};
            my $drive = $bdc->add_iso_drive('usbstick', $iso, 'usb-storage', $size);
            $drive->bootindex(0) if $bootfrom ne "disk";
        }
        else {
            my $drive = $bdc->add_iso_drive('cd0', $iso, $vars->{CDMODEL}, $size);
            $drive->serial('cd0');
            $drive->bootindex(0) if $bootfrom eq "cdrom";
        }
    }
    my $is_first = 1;
    for my $k (sort grep { /^ISO_\d+$/ } keys %$vars) {
        my $addoniso = File::Spec->rel2abs($vars->{$k});
        my $i        = $k;
        $i =~ s/^ISO_//;

        my $size  = $self->get_img_size($addoniso);
        my $drive = $bdc->add_iso_drive("cd$i", $addoniso, $vars->{CDMODEL}, $size);
        $drive->serial("cd$i");
        # first connected cdrom gets ",bootindex=0 when booting from cdrom and
        # there wasn't `ISO` defined
        if ($is_first && $bootfrom eq "cdrom" && !$iso) {
            $drive->bootindex(0);
            $is_first = 0;
        }
    }

    return $self;
}

=head3 configure_pflash

Configure a pair of pflash drives which contain the UEFI firmware code and
variables. Unfortunately pflash drives are handled differently by QEMU than
other block devices which slightly complicates things. See BlockDevConf.pm.

=cut
sub configure_pflash {
    my ($self, $vars) = @_;
    my $bdc = $self->blockdev_conf;

    return $self unless $vars->{UEFI};

    if ($vars->{UEFI_PFLASH}) {
        die 'Mixing old and new PFLASH variables'
          if ($vars->{UEFI_PFLASH_CODE} || $vars->{UEFI_PFLASH_VARS});

        my $file = $vars->{BIOS};
        $bdc->add_pflash_drive('pflash', $file, $self->get_img_size($file));
        return;
    }

    my $fw = $vars->{UEFI_PFLASH_CODE};
    if ($fw) {
        $bdc->add_pflash_drive('pflash-code', $fw, $self->get_img_size($fw))
          ->unit(0)
          ->readonly('on');

        $fw = File::Spec->rel2abs($vars->{UEFI_PFLASH_VARS});
        die 'Need UEFI_PFLASH_VARS with UEFI_PFLASH_CODE' unless $fw;
        $bdc->add_pflash_drive('pflash-vars', $fw, $self->get_img_size($fw))
          ->unit(1);
    }
    elsif ($vars->{UEFI_PFLASH_VARS}) {
        die 'Need UEFI_PFLASH_CODE with UEFI_PFLASH_VARS';
    }

    return $self;
}

=head3 gen_cmdline

Generate the QEMU command line arguments from our object model.

=cut
sub gen_cmdline {
    my $self = shift;

    return ($self->qemu_bin,
        @{$self->_static_params},
        map { $_->gen_cmdline() } @{$self->_mut_params});
}

=head3 init_blockdev_images

Create and delete storage device images based on the current state of the
object model e.g. if block devices are marked as needs_creating then this will
create them.

This should only be called when QEMU is not running.

=cut
sub init_blockdev_images {
    my $self = shift;

    for my $file ($self->blockdev_conf->gen_unlink_list()) {
        no autodie 'unlink';
        unlink($file) if -e $file;
    }

    my $tries = $ENV{QEMU_IMG_CREATE_TRIES} // 3;
    for my $qicmd ($self->blockdev_conf->gen_qemu_img_cmdlines()) {
        for (1 .. $tries) {
            undef $@;
            eval { runcmd($self->qemu_img_bin, @$qicmd) };
            last unless $@;
            bmwqemu::diag("init_blockdev_images: '@$qicmd' failed: $@, try $_ out of $tries");
        }
        die "init_blockdev_images: '@$qicmd' failed after $tries tries: $@" if $@;
    }

    $self->blockdev_conf->mark_all_created();
}

=head3 export_blockdev_images

Convert some of the drive devices' block device chains to single qcow2
images. This amalgamates all the differential snapshots (overlay images) into
a single qcow2 file. This is used to publish 'hard drive' and pflash
images. This function uses qemu-img so can not be used while QEMU is running.

Note that this just exports the block device images which do not contain the
VM RAM state. In order to publish a snapshot of a running machine you also
need to export the VM state (migration) file, which is effectively the same
thing as performing an offline migration.

=cut
sub export_blockdev_images {
    my ($self, $filter, $img_dir, $name) = @_;
    my $count = 0;

    for my $qicmd ($self->blockdev_conf->gen_qemu_img_convert($filter, $img_dir, $name)) {
        runcmd('nice', 'ionice', $self->qemu_img_bin, @$qicmd);

        my $img        = "$img_dir/$name";
        my $exp_format = OpenQA::Qemu::DriveDevice::QEMU_IMAGE_FORMAT;
        my $format     = $self->get_img_format($img);
        die "'$format': unexpected format for '$img' (expected '$exp_format'), maybe snapshotting failed" unless $format eq $exp_format;

        $count++;
    }

    return $count;
}

=head3 gen_runfile

Create a shell script which will execute QEMU with the same parameters which
we are using.

=cut
sub gen_runfile {
    my $self = shift;

    open(my $cmdfd, '>', 'runqemu');
    print $cmdfd "#!/bin/bash\n";
    my @args;
    for my $arg ($self->_static_params) {
        $arg =~ s,\\,\\\\,g;
        $arg =~ s,\$,\\\$,g;
        $arg =~ s,\",\\\",g;
        $arg =~ s,\`,\\\`,;
        push(@args, "\"$arg\"");
    }
    printf $cmdfd "%s \\\n  %s \\\n  \"\$@\"\n", $self->qemu_bin, join(" \\\n  ", @args);
    close $cmdfd;
    chmod 0755, 'runqemu';
}

sub exec_qemu {
    my ($self) = @_;

    my @params = $self->gen_cmdline();
    session->enable;
    bmwqemu::diag('starting: ' . join(' ', @params));
    session->enable_subreaper;

    my $process = $self->_process;
    $self->{_qemu_terminated} = 0;
    $process->on(
        collected => sub {
            $self->{_qemu_terminated} = 1;
            bmwqemu::serialize_state(component => 'backend', msg => 'QEMU exited unexpectedly, see log for details')
              unless $self->{_stopping};
        });
    $process->code(sub {
            $SIG{__DIE__} = undef;    # overwrite the default - just exit
            system $self->qemu_bin, '-version';
            # don't try to talk to the host's PA
            $ENV{QEMU_AUDIO_DRV} = "none";
            exec(@params);
    });
    $process->separate_err(0)->start();

    fcntl($process->read_stream, Fcntl::F_SETFL, Fcntl::O_NONBLOCK) or die "can't setfl(): $!\n";
    return $process->read_stream;
}

sub stop_qemu {
    my ($self) = @_;

    $self->{_stopping} = 1;
    $self->_process->stop;
}

sub qemu_pid { shift->_process->process_id }

=head3 connect_qmp

Connect to QEMU's QMP command socket so that we can control QEMU's execution
using the JSON QAPI. QMP and QAPI are documented in the QEMU source tree.

=cut
sub connect_qmp {
    my ($self) = @_;

    my $sk;
    osutils::attempt {
        attempts  => $ENV{QEMU_QMP_CONNECT_ATTEMPTS} // 20,
        condition => sub { $sk },
        or        => sub { die "Can't open QMP socket" },
        cb        => sub {
            die 'QEMU terminated before QMP connection could be established' if $self->{_qemu_terminated};
            $sk = IO::Socket::UNIX->new(
                Type     => IO::Socket::UNIX::SOCK_STREAM,
                Peer     => 'qmp_socket',
                Blocking => 0
            );
        },
    };

    $sk->autoflush(1);
    binmode $sk;
    my $flags = fcntl($sk, Fcntl::F_GETFL, 0) or die "Can't get file status flags of QMP socket: $!\n";
    $flags = fcntl($sk, Fcntl::F_SETFL, $flags | Fcntl::O_NONBLOCK) or die "Can't set file status flags of QMP socket: $!\n";
    return $sk;
}

=head3 revert_to_snapshot

Roll back the SUT to a previous state, including its temporary and permanent
storage as well as its CPU.

=cut
sub revert_to_snapshot {
    my ($self, $name) = @_;
    my $bdc = $self->blockdev_conf;

    my $snapshot = $self->snapshot_conf->revert_to_snapshot($name);
    $bdc->for_each_drive(sub {
            my $drive     = shift;
            my $del_files = $bdc->revert_to_snapshot($drive, $snapshot);

            die "Snapshot $name not found for " . $drive->id unless defined($del_files);

            for my $file (@$del_files) {
                bmwqemu::diag("Unlinking $file");
                POSIX::remove($file);
            }
    });

    $self->init_blockdev_images();

    return $snapshot;
}

=head3 serialise_state

Serialise our object model of QEMU to JSON and return the JSON text.

=cut
sub serialise_state {
    my ($self) = @_;

    return encode_json({
            blockdev_conf   => $self->blockdev_conf->to_map(),
            controller_conf => $self->controller_conf->to_map(),
            snapshot_conf   => $self->snapshot_conf->to_map(),
    });
}

=head3 save_state

Save our object model of QEMU to a file.

=cut
sub save_state {
    my ($self) = @_;

    if ($self->has_state) {
        bmwqemu::fctinfo('Saving QEMU state to ' . STATE_FILE);
        path(STATE_FILE)->spurt($self->serialise_state());
    } else {
        bmwqemu::fctinfo('Refusing to save an empty state file to avoid overwriting a useful one');
    }

    return $self;
}

=head3 deserialise_state

Deserialise our object model from a string of JSON text.

=cut
sub deserialise_state {
    my ($self, $json) = @_;
    my $state_map = decode_json($json);

    $self->snapshot_conf->from_map($state_map->{snapshot_conf});
    $self->controller_conf->from_map($state_map->{controller_conf});
    $self->blockdev_conf->from_map($state_map->{blockdev_conf},
        $self->controller_conf,
        $self->snapshot_conf);

    return $self;
}

=head3 load_state

Load our object model of QEMU from a file.

=cut
sub load_state {
    my ($self) = @_;

    # In order to remove this, you need to merge the new state with the
    # existing state from disk without breaking existing snapshots (block
    # devices).
    die 'Trying to load state on top of existing state'
      if $self->has_state;

    return $self->deserialise_state(path(STATE_FILE)->slurp());
}

=head3 has_state

Returns true if our object model of QEMU has been populated with non-default
state.

=cut
sub has_state {
    my $self = shift;

    return scalar(grep { $_->has_state } @{$self->_mut_params});
}

1;
