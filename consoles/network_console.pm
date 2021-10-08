# Copyright 2009-2013 Bernhard M. Wiedemann
# Copyright 2019-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package consoles::network_console;

use Mojo::Base -strict;

use base 'consoles::console';

use Try::Tiny;
use Scalar::Util 'blessed';

sub activate {
    my ($self) = @_;
    try {
        local $SIG{__DIE__} = undef;
        $self->connect_remote($self->{args});
        return $self->SUPER::activate;
    }
    catch {
        die $_ unless blessed $_ && $_->can('rethrow');
        return {error => $_->error};
    };
}

# to be overwritten
sub connect_remote { }

1;
