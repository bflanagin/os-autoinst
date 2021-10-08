# Copyright 2016 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package backend::virt;

use Mojo::Base -strict;

use base 'backend::baseclass';

use testapi 'get_var';
use bmwqemu;

sub new {
    my ($class) = @_;
    my $self = $class->SUPER::new;
    $bmwqemu::vars{QEMURAM}  //= 1024;
    $bmwqemu::vars{QEMUCPUS} //= 1;
    return $self;
}


1;
