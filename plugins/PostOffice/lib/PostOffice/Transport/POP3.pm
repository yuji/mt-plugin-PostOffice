package PostOffice::Transport::POP3;

use strict;
use base qw(PostOffice::Transport);

sub init {
    my $obj = shift;
    my (%param) = @_;

    require Mail::POP3Client;
    $obj->{client} = new Mail::POP3Client(
        USER     => $param{username},
        PASSWORD => $param{password},
        HOST     => $param{host},
        ($param{ssl} ? ( USESSL => 'true' ) : () ),
        #DEBUG    => 1,
    ) or die "Failed to connect: " . $@;
}

sub remove {
    my $obj = shift;
    my ($msg) = @_;
    my $client = $obj->{client};
    return undef unless $client;
    return $client->Delete($msg->{sequence});
}

sub message_iter {
    my $obj = shift;

    my $client = $obj->{client};
    return undef unless $client;

    my $count = $client->Count();
    return undef unless $count;

    my $counter = 1;

    sub {
        if ($counter > $count) {
            $client->Close();
            return undef;
        }

        my $msg = {};

        my $last_key;
        foreach ( $client->Head($counter) ) {
            if ( m/^([^\s][^:]+?):\s*(.+)$/ ) {
                $last_key = lc $1;
                $msg->{$last_key} = $2;
            } elsif (defined $last_key) {
                $msg->{$last_key} .= "\n" . $_;
            }
        }

        # get Body
        $msg->{body} = $client->Body($counter);
        $msg->{message} = $client->HeadAndBody($counter);
        $msg->{sequence} = $counter;
        $counter++;

        $msg;
    };
}

1;
