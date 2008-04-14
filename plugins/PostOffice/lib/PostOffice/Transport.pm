package PostOffice::Transport;

use strict;

sub new {
    my $class = shift;
    my $obj = bless {}, $class;
    $obj->init(@_);
    $obj;
}

sub init;
sub message_iter;

1;
