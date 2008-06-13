package PostOffice;

use strict;

our $DEBUG = 0;

sub plugin {
    return MT->component('postoffice');
}

sub deliver {
    my $pkg = shift;

    my $plugin = $pkg->plugin;
    require MT::PluginData;
    my $pd_iter = MT::PluginData->load_iter( { plugin => $plugin->key } );
    return unless $pd_iter;

    my $count = 0;
    while ( my $pd = $pd_iter->() ) {
        next unless $pd->key =~ m/^configuration:blog:(\d+)/;
        my $blog_id = $1;
        print "Checking inbox for blog $blog_id...\n"
          if $DEBUG;
        my $cfg = $pd->data() || {};
        next unless $cfg->{email_username};
        my $blog_count = $pkg->process_messages( $blog_id, $cfg );
        if ( defined $blog_count ) {
            print "Delivered $blog_count messages for blog $blog_id...\n"
              if $DEBUG;
            $count += $blog_count;
        }
    }

    my $sys_cfg = $plugin->get_config_hash() || {};
    if ( $sys_cfg->{email_username} ) {
        print "Checking inbox for system-configured inbox...\n";
        my $sys_count = $pkg->process_messages( undef, $sys_cfg );
        if ( defined $sys_count ) {
            print "Delivered $sys_count messages...\n"
              if $DEBUG;
            $count += $sys_count;
        }
    }

    $count;
}

sub save_attachment {
    my $pkg = shift;
    my ( $blog, $file ) = @_;

    require MT::Asset;
    my $asset_pkg = MT::Asset->handler_for_file( $file->{path} );
    my $asset;
    $asset = $asset_pkg->new();
    $asset->file_path( $file->{path} );
    $asset->file_name( $file->{name} );
    $file->{name} =~ /(.*)(?:\.)(.*$)/;
    $asset->file_ext($2);
    $asset->url( $file->{url} );
    $asset->mime_type( $file->{media_type} );
    $asset->blog_id( $blog->id );
    $asset->save || return undef;

    MT->run_callbacks(
        'api_upload_file.' . $asset->class,
        File  => $file->{path},
        file  => $file->{path},
        Url   => $file->{url},
        url   => $file->{url},
        Size  => $file->{size},
        size  => $file->{size},
        Asset => $asset,
        asset => $asset,
        Type  => $asset->class,
        type  => $asset->class,
        $blog ? ( Blog => $blog ) : (),
        $blog ? ( blog => $blog ) : ()
    );

    $asset;
}

sub _parse_content_type {
    my ($content_type) = @_;

    require Email::MIME::ContentType;
    my $data = Email::MIME::ContentType::parse_content_type($content_type);
    my $media_type = $data->{discrete} . "/" . $data->{composite};
    my $charset    = $data->{attributes}->{charset};
    ( $media_type, $charset );
}

sub _unique_filename {
    my ( $fmgr, $site_path, $filename ) = @_;

    require File::Basename;
    my ( $basename, undef, $suffix ) =
      File::Basename::fileparse( $filename, qr/\.[^.]*/ );
    require File::Spec;
    my $u = '';
    my $i = 1;
    while (
        $fmgr->exists(
            File::Spec->catfile( $site_path, $basename . $u . $suffix )
        )
      )
    {
        $u = '_' . $i++;
    }
    $basename . $u . $suffix;
}

sub process_message_parts {
    my $pkg = shift;
    my ( $blog, $msg ) = @_;

    require Email::MIME;
    my $parsed = Email::MIME->new( $msg->{message} );

    require MT::I18N;
    my $charset;
    my $text;
    my @files;
    my @parts = $parsed->parts;

    foreach my $part (@parts) {
        my ( $media_type, $charset ) =
          _parse_content_type( $part->header('Content-Type') );
        if ( $media_type eq 'text/plain' ) {
            $text = MT::I18N::encode_text( $part->body, $charset );
        }
        else {
            if ( $part->filename ) {
                my $filename =
                  MT::I18N::encode_text( $part->filename, $charset );
                my $fmgr = $blog->file_mgr;
                $filename =
                  _unique_filename( $fmgr, $blog->site_path, $filename );
                require File::Spec;
                my $filepath =
                  File::Spec->catfile( $blog->site_path, $filename );
                my $bytes = $fmgr->put_data( $part->body, $filepath );
                my $file = {
                    name       => $filename,
                    path       => $filepath,
                    url        => $blog->site_url . $filename,
                    media_type => $media_type,
                    size       => $bytes,
                };
                my $asset = $pkg->save_attachment( $blog, $file );

                if ($asset) {
                    $file->{asset_id}    = $asset->id;
                    $file->{asset_class} = $asset->class;
                    push @files, $file;
                }
            }
        }
    }
    $msg->{subject} =
      MT::I18N::encode_text( $parsed->header("Subject"), $charset );
    $text .= '<br />' if @files > 0;
    foreach my $file (@files) {
        $text .=
            '<form contenteditable="false" mt:asset-id="'
          . $file->{asset_id}
          . '" class="mt-enclosure mt-enclosure-'
          . $file->{asset_class}
          . '" style="display: inline;">';

        if ( $file->{media_type} =~ /^image/ ) {
            $text .=
                '<img alt="" src="'
              . $file->{url}
              . '" class="mt-image-none" style="" />';
        }
        else {
            $text .= '<a href="' . $file->{url} . '">' . $file->{name} . '</a>';
        }

        $text .= '</form><div><br /></div>';
    }

    # TBD: Allow user to specify the sanitize spec for this
    require MT::Sanitize;
    MT::Sanitize->sanitize( $text,
        "a href,b,i,strong,em,p,br/,ul,li,ol,blockquote,pre" );
    $msg->{text}  = $text;
    $msg->{files} = \@files;
}

sub _get_valid_addresses {
    my $pkg = shift;
    my ( $blog_id, $cfg ) = @_;

    # Get Addresses out of plugindata
    my @addresses = split( /\s*,\s*/, lc( $cfg->{allowed_emails} || '' ) );
    my %addresses;
    $addresses{$_} = 1 for @addresses;

    require MT::Permission;
    require MT::Author;

    # FIXME: This doesn't include any sysadmins who have no direct
    # relationship with the blog...
    if ( $cfg->{allow_mt_authors} ) {

        # get addresses for this blog
        my $iter = MT::Permission->load_iter( { blog_id => $blog_id, } );
        while ( my $perm = $iter->() ) {
            my $au = MT::Author->load( { id => $perm->author_id } );
            if ( $au && $au->email ) {
                $addresses{ lc $au->email } = $au;
            }
        }
    }
    \%addresses;
}

sub process_message {
    my $pkg = shift;
    my ( $blog_id, $cfg, $au, $perm, $msg ) = @_;

    require MT::Blog;
    my $blog = MT::Blog->load($blog_id);

    $pkg->process_message_parts( $blog, $msg );

    require MT::Entry;
    my $entry = MT::Entry->new();
    $entry->title( $msg->{subject} );
    $entry->text( $msg->{text} );
    $entry->author_id( $au->id );
    $entry->blog_id($blog_id);
    $entry->status( $cfg->{post_status} || 1 );

    MT->run_callbacks(
        'postoffice_pre_save',
        blog_id     => $blog_id,
        config      => $cfg,
        author      => $au,
        permissions => $perm,
        message     => $msg,
        entry       => $entry,
    );

    print "Saving entry [" . $entry->title . "]\n"
      if $DEBUG;

    $entry->save
      or return 0;

    my $cat;
    my $place;
    if ( $msg->{category} ) {
        require MT::Category;
        $cat = MT::Category->load( { label => $msg->{category} } );
        unless ($cat) {
            if ( $perm->can_edit_categories ) {
                $cat = MT::Category->new();
                $cat->blog_id($blog_id);
                $cat->label( $msg->{category} );
                $cat->parent(0);
                $cat->save
                  or die $cat->errstr;
            }
        }

        if ($cat) {
            require MT::Placement;
            $place = MT::Placement->new;
            $place->entry_id( $entry->id );
            $place->blog_id($blog_id);
            $place->category_id( $cat->id );
            $place->is_primary(1);
            $place->save
              or die $place->errstr;
        }
    }

    MT->run_callbacks(
        'postoffice_post_save',
        blog_id     => $blog_id,
        config      => $cfg,
        author      => $au,
        permissions => $perm,
        message     => $msg,
        entry       => $entry,
        ( $cat   ? ( category  => $cat )   : () ),
        ( $place ? ( placement => $place ) : () ),
    );

    if ( $entry->status == 2 ) {    # publish
        MT->rebuild_entry(
            Entry             => $entry,
            BuildDependencies => 1,
        );
    }

    MT->run_callbacks( 'api_post_save.entry', MT->instance, $entry, undef );

    1;
}

sub process_messages {
    my $pkg = shift;
    my ( $blog_id, $cfg ) = @_;

    my $app = MT->app;
    if ( $app->isa('MT::App') ) {
        $blog_id ||= $app->param('blog_id');
    }

    $cfg ||= $blog_id ? $pkg->plugin->get_config_hash('blog:' . $blog_id) : $pkg->plugin->get_config_hash();

    my $default_author_id = $cfg->{default_author};
    require MT::Author;
    my $default_author = MT::Author->load($default_author_id)
      if $default_author_id;

    my $xp = $pkg->transport($cfg)
      or die "PostOffice: No mail transport configured";
    my $iter = $xp->message_iter or return 0;

    require Email::Address;
    my $count = 0;

    my $addresses_by_blog = {};

    while ( my $msg = $iter->() ) {

        # determine blog_id for active message
        my $extension = $msg->{to};
        my $api_key;
        my $local_blog_id = $blog_id;
        if ( $extension =~ m/^[^@]+\+(.+?)@/ ) {
            $extension = $1;
            if ( $extension =~ m!^(?:(.+)\.)?(\d+)$! ) {
                $local_blog_id = $2;
                $api_key = $1 if $1;
            }
            else {
                $api_key = $extension;
            }
        }
        else {
            $extension = undef;
        }
        if ( !$local_blog_id ) {
            print STDERR "PostOffice: No blog_id parameter present for message "
              . $msg->{'message-id'}
              . " from "
              . $msg->{from} . "\n";
        }

        my $addresses = $addresses_by_blog->{$local_blog_id} ||=
          $pkg->_get_valid_addresses( $local_blog_id, $cfg );

        my ($addr) = Email::Address->parse( $msg->{from} );
        if ( !$addr ) {
            print STDERR "PostOffice: error parsing 'from' address for message "
              . $msg->{'message-id'}
              . " from "
              . $msg->{from} . "\n";
            next;
        }
        my $from = lc $addr->address;
        unless ( $addresses->{$from} ) {
            print STDERR "PostOffice: Unknown author address for message "
              . $msg->{'message-id'}
              . " from "
              . $msg->{from} . "\n";
            next;
        }

        my $au =
          ref $addresses->{$from}
          ? $addresses->{$from}
          : MT::Author->load( { email => $from } );
        $au ||= $default_author;
        if ( !$au ) {
            print STDERR "PostOffice: No MT author found for message "
              . $msg->{'message-id'}
              . " from "
              . $msg->{from} . "\n";
            next;
        }

        # Test for API key requirement
        if ( $cfg->{require_api_key} ) {
            if ( !$api_key ) {

                # TBD: Log API key missing message??
                print STDERR "PostOffice: Missing API key for message "
                  . $msg->{'message-id'}
                  . " from "
                  . $msg->{from} . " to "
                  . $msg->{to} . "\n";
                next;
            }

            # TBD: Log incorrect API key?
            require MT::Util;
            if (
                $api_key
                && ( MT::Util::perl_sha1_digest_hex( $au->api_password ) ne
                    $api_key )
              )
            {
                print STDERR "PostOffice: Invalid API key for message "
                  . $msg->{'message-id'}
                  . " from "
                  . $msg->{from} . " to "
                  . $msg->{to} . "\n";
                next;
            }
        }

        require MT::Permission;
        my $perm =
          MT::Permission->load(
            { author_id => $au->id, blog_id => $local_blog_id } );
        next unless $perm;

        $au->is_superuser || $perm->can_administer_blog || $perm->can_post
          or next;

        if ( $msg->{subject} =~ m/^.*\[([^\]]+?)\]\s*(.+)$/ ) {
            $msg->{category} = $1;
            $msg->{subject}  = $2;
        }

        if ( $pkg->process_message( $local_blog_id, $cfg, $au, $perm, $msg ) ) {
            $xp->remove($msg);
            $count++;
        }
    }

    $count;
}

sub transport {
    my $pkg            = shift;
    my ($cfg)          = @_;
    my $transport      = lc( $cfg->{email_transport} ) || 'pop3';
    my $all_transports = MT->registry("postoffice_transports");
    my $tp             = $all_transports->{$transport};
    my $label          = $tp->{label};
    $label = $label->() if ref($label);
    my $class = $tp->{class} if $tp;
    $class ||= 'PostOffice::Transport::POP3';
    eval qq{require $class; 1;}
      or die "PostOffice: failed to load transport class $class";

    print "Connecting to " . $label . " server " . $cfg->{email_host} . "...\n"
      if $DEBUG;

    my %param = (
        %$cfg,
        username => $cfg->{email_username},
        password => $cfg->{email_password},
        host     => $cfg->{email_host},
        ssl      => $cfg->{use_ssl},
    );
    $class->new(%param);
}

1;
