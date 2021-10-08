#!/bin/sh

# Installation tools

# Get all dependencies needed for the container environment
getdeps_container() {
    perl -MYAML::PP=Load -0wE'
        my $d = Load<>;
        say for sort grep {!/^%/} map { keys %{$d->{$_."_requires"}} }
        @{$d->{targets}->{docker}}
    ' < dependencies.yaml
}

listdeps() {
    rpm -qa --qf "%{NAME}-%{VERSION}\n" | grep -v ^gpg-pubkey | sort
}
