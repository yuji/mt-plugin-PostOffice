package PostOffice::Transport::IMAP;

use strict;
use base qw(PostOffice::Transport);

sub init {
    my $obj = shift;
    my (%param) = @_;

    require Mail::IMAPClient;
    $obj->{client} = new Mail::IMAPClient(
        Server   => $param{host},
        User     => $param{username},
        Password => $param{password},
    ) or die "Failed to connect: " . $@;

    $obj->{imap_folder} = $param{imap_folder};
    $obj->{client}->Connected()
        or die "Failed to connect";
    $obj->{client}->Authenticated()
        or die "Failed to authenticate";

    return $obj;
}

sub remove {
    my $obj = shift;
    my ($msg) = @_;

    my $client = $obj->{client};
    return undef unless $client;

    $client->delete_message($msg->{sequence});

    return 1;
}

sub message_iter {
    my $obj = shift;

    my $client = $obj->{client};
    return undef unless $client;

    $client->select($obj->{imap_folder} || "INBOX");

    # my $count = $client->message_count();
    # return undef unless $count;

    my $msgs = $client->messages;
    return undef unless $msgs && @$msgs;

    return sub {
        if (!@$msgs) {
            $client->close();
            return undef;
        }

        my $msg = {};
        my $msg_seq = shift @$msgs;

        my $headers = $client->parse_headers($msg_seq, 'ALL');

        my $last_key;
        foreach ( keys %$headers ) {
            $last_key = lc $_;
            my $value = $headers->{$_};
            if ((ref($value) eq 'ARRAY') && (scalar @$value == 1)) {
                $value = $value->[0];
            }
            $msg->{lc $_} = $value;
        }
        $msg->{body} = $client->body_string($msg_seq);
        $msg->{message} = $client->message_string($msg_seq);
        $msg->{sequence} = $msg_seq;

        $msg;
    };
}

1;
