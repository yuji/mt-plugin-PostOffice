package PostOffice::CMS;

use strict;

sub edit_entry_src {
    my $cb = shift;
    my ($app, $tmpl) = @_;
    my $plugin = $cb->plugin;

    my $user = $app->user;
    return unless $user && $user->api_password;

    my $blog_id = $app->blog->id;
    my $cfg = $plugin->get_config_hash('blog:' . $blog_id);
    if (!$cfg->{email_username}) {
        $cfg = $plugin->get_config_hash();
    }
    return unless $cfg->{email_username};

    my $ext = $blog_id;
    if ($cfg->{require_api_key}) {
        require MT::Util;
        $ext = MT::Util::perl_sha1_digest_hex($user->api_password) . '.' . $blog_id;
    }
    my $mailto = $cfg->{email_address};
    $mailto =~ s/@/+$ext@/;

    my $out = <<EOT;
<div id="postoffice">
    <__trans phrase="[_1]Email to [_2]</a> - Save this address to post to this blog by email." params="<a href='mailto:$mailto'>%%<mt:var name='blog_name' escape='html'>">
</div>
EOT
    $$tmpl =~ s!(<div id="quickpost">)!$out$1!;
}

sub config_template {
    my ($plugin, $param, $scope) = @_;
    my @allowed_authors;
    my $config = $plugin->get_config_hash($scope);
    my $default_author = $config->{default_author} || 0;
    my @authors = MT::Author->load( { type => 1 } ); # only authors
    if ($scope =~ m/blog:/) {
        $scope =~ s/blog://;
        foreach my $iter (@authors) {
            my $perms = MT::Permission->load({ blog_id => $scope, author_id => $iter->id });
            if ($perms) {
                push @allowed_authors, $iter;
            }
        }
    }
    else {
        @allowed_authors = @authors;
    }

    my $author_options = '';
    foreach my $a (@allowed_authors) {
        $author_options .= "<option value=\"" . $a->id . "\"";
        if ($a->id == $default_author) {
            $author_options .= " selected=\"selected\"";
        }
        $author_options .= ">" . MT::Util::encode_html($a->name) . "</option>\n";
    }

    my $transport = lc($config->{email_transport}) || 'pop3';
    my $transports = '';
    my $app = MT->instance;
    my $all_transports = $app->registry("postoffice_transports") || {};
    $all_transports = $app->filter_conditional_list($all_transports);
    foreach my $t (keys %$all_transports) {
        my $tp = $all_transports->{$t};
        $transports .= qq{<option value="$t" };
        if ($t eq $transport) {
            $transports .= 'selected="selected"';
        }
        my $label = $tp->{label};
        $label = $label->() if ref($label);
        $transports .= qq{>$label</option>\n};
    }

    my $imap_selected = $transport eq 'imap';
    if (!$imap_selected) {
        $config->{imap_folder} = undef;
    }

    my $form =  <<HTML;
<mtapp:setting
    id="email_address"
    label="<__trans phrase="Destination Inbox">"
    show_hint="1"
    hint="<__trans phrase="This is the email address authors send posts to when they want Movable Type to post those messages to this blog.">">
    <input name="email_address" id="email_address" value="<mt:var name="email_address" escape="html">" size="30" />
</mtapp:setting>

<mtapp:setting
    id="email_transport"
    label="<__trans phrase="Mail Server Type">">
    <select id="email_transport" name="email_transport">
        $transports
    </select>
</mtapp:setting>

<mtapp:setting
    id="email_host"
    label="<__trans phrase="Email Account host">"
    show_hint="1"
    hint="<__trans phrase="This is the host for the email account which Movable Type uses to post to this blog.">">
    <input name="email_host" id="email_host" value="<mt:var name="email_host" escape="html">" size="30" />
</mtapp:setting>

<mtapp:setting
    id="use_ssl"
    label="<__trans phrase="Use SSL">"
    show_hint="1"
    hint="<__trans phrase="The host requires an encrypted connection.">">
    <input type="checkbox" name="use_ssl" <mt:if name="use_ssl">checked="checked"</mt:if> id="use_ssl"  class="cb" />
</mtapp:setting>

<mtapp:setting
    id="imap_folder"
    label="<__trans phrase="IMAP Folder">"
    show_hint="1"
    shown="$imap_selected"
    hint="<__trans phrase="The IMAP folder to check for new posts.">">
    <input id="imap_folder" type="text" size="30" name="imap_folder" value="<mt:var name="imap_folder" escape="html">" />
</mtapp:setting>

<mtapp:setting
    id="email_username"
    label="<__trans phrase="Email Account Username">"
    show_hint="1"
    hint="<__trans phrase="This is the username for the email account which Movable Type uses to post to this blog.">">
    <input name="email_username" id="email_username" value="<mt:var name="email_username" escape="html">" size="30" />
</mtapp:setting>

<mtapp:setting
    id="email_password"
    label="<__trans phrase="Email Account Password">"
    show_hint="1"
    hint="<__trans phrase="This is the password for the email account which Movable Type uses to post to this blog.">">
    <input type="password" name="email_password" id="email_password" value="<mt:var name="email_password" escape="html">" size="30" />
</mtapp:setting>

<mtapp:setting
    id="post_status"
    label="<__trans phrase="Default post status">"
    show_hint="1"
    hint="<__trans phrase="This determines if posts are automatically published as they are received or if they must be manually published.">">
    <select name="post_status">
        <option<mt:if name="post_status" eq="2"> selected="selected"</mt:if> value="2"><__trans phrase="Published"></option>
        <option<mt:if name="post_status" eq="1"> selected="selected"</mt:if> value="1"><__trans phrase="Draft"></option>
    </select>
</mtapp:setting>

<mtapp:setting
    id="description"
    label="<__trans phrase="Email addresses allowed to post (comma separated)">"
    show_hint="1"
    hint="<__trans phrase="Movable Type will post messages received from these email addresses.">">
    <textarea name="allowed_emails" id="allowed_emails" cols="50" rows="2"><mt:var name="allowed_emails" escape="html"></textarea>
</mtapp:setting>

<mtapp:setting
    id="allow_mt_authors"
    label="<__trans phrase="Allow all MT authors from this blog to post">"
    show_hint="1"
    hint="<__trans phrase="If you check this box, Movable Type will allow all of the authors of this weblog to post via email using the email address in their author profile.">">
    <input type="checkbox" name="allow_mt_authors" <mt:if name="allow_mt_authors">checked="checked"</mt:if> id="allow_mt_authors"  class="cb" />
</mtapp:setting>

<mtapp:setting
    id="require_api_key"
    label="<__trans phrase="Require API key in address (i.e., user+mtapikey@...)">"
    show_hint="1"
    hint="<__trans phrase="If you check this box, PostOffice will require users to include their API key as an extension on their e-mail address. So the 'From' address should contain a '+' followed by their API key value. This provides additional authentication for incoming messages.">">
    <input type="checkbox" name="require_api_key" <mt:if name="require_api_key">checked="checked"</mt:if> id="require_api_key"  class="cb" />
</mtapp:setting>

<mtapp:setting
    id="default_author"
    label="<__trans phrase="Default Author">"
    show_hint="1"
    hint="<__trans phrase="This is the 'default' author, the person to whom entries are assigned if no other valid author exists.">">
    <select name="default_author">
        $author_options
    </select>
</mtapp:setting>
HTML

    return $form;
}

1;
