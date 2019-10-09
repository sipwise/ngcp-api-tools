package NGCP::API::Client;
use strict;
use warnings;
use feature qw(state);

use English qw(-no_match_vars);
use Carp;
use Config::Tiny;
use JSON::XS;
use IO::Socket::SSL;
use LWP::UserAgent;
use Readonly;
use URI;

sub _load_config_defaults {
    my $cfg_file = '/etc/default/ngcp-api';
    my $cfg;

    $cfg = Config::Tiny->read($cfg_file)
        or croak("Cannot read $cfg_file: $ERRNO");

    Readonly my $config => {
        host          => $cfg->{_}->{NGCP_API_IP} // '127.0.0.1',
        port          => $cfg->{_}->{NGCP_API_PORT} // 80,
        iface         => $cfg->{_}->{NGCP_API_IFACE} // 'lo',
        sslverify     => $cfg->{_}->{NGCP_API_SSLVERIFY} // 'yes',
        sslverify_lb  => $cfg->{_}->{NGCP_API_SSLVERIFY_LOOPBACK} // 'no',
        read_timeout  => $cfg->{_}->{NGCP_API_READ_TIMEOUT} // 180,
        page_rows     => $cfg->{_}->{NGCP_API_PAGE_ROWS} // 10,
        auth_user     => $cfg->{_}->{AUTH_SYSTEM_LOGIN},
        auth_pass     => $cfg->{_}->{AUTH_SYSTEM_PASSWORD},
        verbose       => 0,
    };

    return $config;
}

sub _get_config_defaults {
    state $config = _load_config_defaults();

    return $config;
}

sub _create_ua {
    my $self = shift;

    my $ua = LWP::UserAgent->new();
    if ($self->{_opts}{sslverify} eq 'no' ||
        ($self->{_opts}{sslverify_lb} eq 'no' &&
         $self->{_opts}{iface} =~ /^(lo|dummy)/)) {
        $ua->ssl_opts(
            verify_hostname => 0,
            SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE,
        );
    }

    my $urlbase = URI->new();
    $urlbase->scheme('https');
    $urlbase->host($self->{_opts}{host});
    $urlbase->port($self->{_opts}{port});

    if (defined $self->{_opts}{auth_user}) {
        $ua->credentials($urlbase->host_port,
                         'api_admin_system', #'api_admin_http'
                         @{$self->{_opts}}{qw(auth_user auth_pass)});
    }

    if ($self->{_opts}{verbose}) {
        $ua->show_progress(1);
        $ua->add_handler("request_send",  sub { shift->dump; return });
        $ua->add_handler("response_done", sub { shift->dump; return });
    }

    $ua->timeout($self->{_opts}{read_timeout});

    $self->{_ua} = $ua;
    $self->{_urlbase} = $urlbase;

    return ($ua,$urlbase);
}

sub _create_req {
    my ($self, $method, $url) = @_;

    my $req = HTTP::Request->new($method, $url->canonical);
    if ($method eq "PATCH") {
        $req->content_type("application/json-patch+json; charset='utf8'");
    } else {
        $req->content_type("application/json; charset='utf8'");
    }
    $req->header('Prefer' => 'return=representation');
    $req->header('NGCP-UserAgent' => 'NGCP::API::Client'); #remove for 'api_admin_http'
    return $req;
}

sub _get_url {
    my ($self, $uri) = @_;

    my $url = $self->{_urlbase}->clone();
    $url->path($uri);

    return $url;
}

sub new {
    my $class  = shift;

    my $self = {
        _opts => { },
    };
    bless $self, $class;

    my $default_opts = _get_config_defaults();
    foreach my $opt (keys %{$default_opts}) {
        $self->{_opts}{$opt} //= $default_opts->{$opt};
    }
    $self->_create_ua();

    return $self;
}

sub request {
    my ($self, $method, $uri, $data) = @_;

    my $req = $self->_create_req($method, $self->_get_url($uri));

    if ($data) {
        $req->content(encode_json($data));
    }

    my $res = $self->{_ua}->request($req);

    return NGCP::API::Client::Result->new($res);
}

sub next_page {
    my ( $self, $uri ) = @_;

    my $collection_url;
    if ($self->{_collection_url}) {
        $collection_url = $self->{_collection_url};
    } else {
        $collection_url = $self->_get_url($uri);

        my %params = $collection_url->query_form;
        $params{page} //= 1;
        $params{rows} //= $self->{_rows};
        $collection_url->query_form(\%params);

        $self->{_collection_url} = $collection_url;
    }

    my $req = $self->_create_req('GET', $collection_url);
    my $res = NGCP::API::Client::Result->new($self->{_ua}->request($req));

    my $data = $res->as_hash();
    if ($data && ref($data) eq 'HASH') {
        my $new_url = URI->new($data->{_links}->{next}->{href});
        return $res unless $new_url;

        my %params = $new_url->query_form;
        return $res unless grep { $_ eq 'page' } keys %params;
        %params = ( $collection_url->query_form, $new_url->query_form );
        $new_url->query_form(\%params);

        $self->{_collection_url} = $self->_get_url($new_url->canonical);
    } else {
        undef $self->{_collection_url};
    }

    return $res;
}

sub set_page_rows {
    my ($self,$rows) = @_;

    $self->{_rows} = $rows;
    undef $self->{_collection_url};

    return;
}

sub set_verbose {
    my $self = shift;

    $self->{_opts}{verbose} = shift // 0;

    return;
}


package NGCP::API::Client::Result;
use warnings;
use strict;
use parent qw(HTTP::Response);

use JSON::XS;

sub new {
    my ($class, $res_obj) = @_;
    my $self = $class->SUPER::new($res_obj->code,
                                  $res_obj->message,
                                  $res_obj->headers,
                                  $res_obj->content);
    $self->{_cached} = undef;
    return $self;
}

sub as_hash {
    my $self = shift;
    return $self->{_cached} if $self->{_cached};
    $self->{_cached} = decode_json($self->content);
    return $self->{_cached};
}

sub result {
    my $self = shift;

    my $location = $self->headers->header('Location') || '';
    return $self->is_success
        ? sprintf "%s %s", $self->status_line, $location
        : sprintf "%s %s", $self->status_line, $self->content;
}

1;

__END__

=pod

=head1 NAME

NGCP::API::Client - Client interface for the REST API

=head1 VERSION

See the package changelog

=head1 COMPATIBILITY

The version is compatible with NGCP platforms version >= mr4.3.x

=head1 SYNOPSIS

=head2

    my $client = new NGCP::API::Client;

    # GET (list)

    my $uri = '/api/customers/';
    my $res = $client->request("GET", $uri);

    # POST (create)

    my $uri = '/api/customers/';
    my $data = { contact_id         => 4,
                 status             => "test",
                 billing_profile_id => 4,
                 type               => "sipaccount" };
    my $res = $client->request("POST", $uri, $data);

    # PUT (update)

    my $uri = '/api/customers/2';
    my $data = { contact_id         => 4,
                 status             => "test",
                 billing_profile_id => 4,
                 type               => "sipaccount" };
    my $res = $client->request("POST", $uri, $data);

    # PATCH (update fields)

    my $uri = '/api/customers/2';
    my $data = [ { op   => "remove",
                   path => "/add_vat" },
                 { op    => "replace",
                   path  => "/contact_id",
                   value => 5 } ];
    my $res = $client->request("PATCH", $uri, $data);

    # DELETE (remove)

    my $uri = '/api/customers/2';
    my $res = $client->request("DELETE", $uri);

    # $res - response is an NGCP::API::Client::Result object

=head1 DESCRIPTION

The client is for internal REST API usage primarily by internal scripts and modules

=head2 new()

Return: NGCP::API::Client object

=head2 request($method, $uri)

Send a REST API request provided by a method (GET,POST,PUT,PATCH,DELETE)

Return: NGCP::API::Client::Result object which is an extended clone of HTTP:Respone

=head2 set_verbose(0|1)

Enable/disable tracing of the request/response.

Return: undef

=head2 NGCP::API::Client::Result->as_hash()

Return: result as a hash reference

=head2 NGCP::API::Client::Result->result()

Return: return a result string based on the request success

=head1 BUGS AND LIMITATIONS

L<https://bugtracker.sipwise.com>

=head1 AUTHOR

Kirill Solomko <ksolomko@sipwise.com>

=head1 LICENSE

This software is Copyright (c) 2016 by Sipwise GmbH, Austria.

All rights reserved. You may not copy, distribute
or modify without prior written permission from
Sipwise GmbH, Austria.

=cut

# vim: sw=4 ts=4 et
