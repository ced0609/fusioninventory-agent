package FusionInventory::Agent::HTTP::Client::GLPI;

use strict;
use warnings;
use base 'FusionInventory::Agent::HTTP::Client';

use Encode;
use English qw(-no_match_vars);
use HTTP::Request;
use JSON;
use UNIVERSAL::require;
use URI;
use URI::Escape;

use FusionInventory::Agent::Message::Inbound;
use FusionInventory::Agent::Tools;

my $log_prefix = "[http client] ";

sub new {
    my ($class, %params) = @_;

    my $self = $class->SUPER::new(%params);

    $self->{ua}->default_header('Pragma' => 'no-cache');

    # check compression mode
    if (Compress::Zlib->require()) {
        # RFC 1950
        $self->{compression} = 'zlib';
        $self->{ua}->default_header('Content-type' => 'application/x-compress-zlib');
        $self->{logger}->debug(
            $log_prefix .
            'Using Compress::Zlib for compression'
        );
    } elsif (canRun('gzip')) {
        # RFC 1952
        $self->{compression} = 'gzip';
        $self->{ua}->default_header('Content-type' => 'application/x-compress-gzip');
        $self->{logger}->debug(
            $log_prefix .
            'Using gzip for compression'
        );
    } else {
        $self->{compression} = 'none';
        $self->{ua}->default_header('Content-type' => 'application/xml');
        $self->{logger}->debug(
            $log_prefix .
            'Not using compression'
        );
    }

    return $self;
}

sub sendJSON {
    my ($self, %params) = @_;

    my $url = ref $params{url} eq 'URI' ?
        $params{url} : URI->new($params{url});

    my $finalUrl = $url.'?action='.uri_escape($params{args}->{action});
    foreach my $k (keys %{$params{args}}) {
        if (ref($params{args}->{$k}) eq 'ARRAY') {
            foreach (@{$params{args}->{$k}}) {
                $finalUrl .= '&'.$k.'[]='.$self->_prepareVal($_ || '');
            }
        } elsif (ref($params{args}->{$k}) eq 'HASH') {
            foreach (keys %{$params{args}->{$k}}) {
                $finalUrl .= '&'.$k.'['.$_.']='.$self->_prepareVal($params{args}->{$k}{$_});
            }
        } elsif ($k ne 'action' && length($params{args}->{$k})) {
            $finalUrl .= '&'.$k.'='.$self->_prepareVal($params{args}->{$k});
        }
   }

    $self->{logger}->debug2($finalUrl) if $self->{logger};

    my $request = HTTP::Request->new(GET => $finalUrl);

    my $response = $self->request($request);

    return unless $response;

    return eval { from_json( $response->content(), { utf8  => 1 } ) };
}

sub sendXML {
    my ($self, %params) = @_;

    my $url = ref $params{url} eq 'URI' ?
        $params{url} : URI->new($params{url});
    my $message = $params{message};
    my $logger  = $self->{logger};

    my $request_content = $message->getContent();
    $logger->debug2($log_prefix . "sending message:\n $request_content");

    $request_content = $self->_compress(encode('UTF-8', $request_content));
    if (!$request_content) {
        $logger->error($log_prefix . 'inflating problem');
        return;
    }

    my $request = HTTP::Request->new(POST => $url);
    $request->content($request_content);

    my $response = $self->request($request);

    # no need to log anything specific here, it has already been done
    # in parent class
    return if !$response->is_success();

    my $response_content = $response->content();
    if (!$response_content) {
        $logger->error($log_prefix . "unknown content format");
        return;
    }

    my $uncompressed_response_content = $self->_uncompress($response_content);
    if (!$uncompressed_response_content) {
        $logger->error(
            $log_prefix . "uncompressed content, starting with: ".substr($response_content, 0, 500)
        );
        return;
    }

    $logger->debug2($log_prefix . "receiving message:\n $uncompressed_response_content");

    my $result;
    eval {
        $result = FusionInventory::Agent::Message::Inbound->new(
            content => $uncompressed_response_content
        );
    };
    if ($EVAL_ERROR) {
        my @lines = split(/\n/, $uncompressed_response_content);
        $logger->error(
            $log_prefix . "unexpected content, starting with $lines[0]"
        );
        return;
    }

    return $result->getContent();
}

sub _prepareVal {
    my ($self, $val) = @_;

    return '' unless length($val);

# forbid to long argument.
    while (length(URI::Escape::uri_escape_utf8($val)) > 1500) {
        $val =~ s/^.{5}/…/;
    }

    return URI::Escape::uri_escape_utf8($val);
}

sub _compress {
    my ($self, $data) = @_;

    return
        $self->{compression} eq 'zlib' ? $self->_compressZlib($data) :
        $self->{compression} eq 'gzip' ? $self->_compressGzip($data) :
                                         $data;
}

sub _uncompress {
    my ($self, $data) = @_;

    if ($data =~ /(\x78\x9C.*)/s) {
        $self->{logger}->debug2("format: Zlib");
        return $self->_uncompressZlib($1);
    } elsif ($data =~ /(\x1F\x8B\x08.*)/s) {
        $self->{logger}->debug2("format: Gzip");
        return $self->_uncompressGzip($1);
    } elsif ($data =~ /(<html><\/html>|)[^<]*(<.*>)\s*$/s) {
        $self->{logger}->debug2("format: Plaintext");
        return $2;
    } else {
        $self->{logger}->debug2("format: Unknown");
        return;
    }
}

sub _compressZlib {
    my ($self, $data) = @_;

    return Compress::Zlib::compress($data);
}

sub _compressGzip {
    my ($self, $data) = @_;

    File::Temp->require();
    my $in = File::Temp->new();
    print $in $data;
    close $in;

    my $out = getFileHandle(
        command => 'gzip -c ' . $in->filename(),
        logger  => $self->{logger}
    );
    return unless $out;

    local $INPUT_RECORD_SEPARATOR; # Set input to "slurp" mode.
    my $result = <$out>;
    close $out;

    return $result;
}

sub _uncompressZlib {
    my ($self, $data) = @_;

    return Compress::Zlib::uncompress($data);
}

sub _uncompressGzip {
    my ($self, $data) = @_;

    my $in = File::Temp->new();
    print $in $data;
    close $in;

    my $out = getFileHandle(
        command => 'gzip -dc ' . $in->filename(),
        logger  => $self->{logger}
    );
    return unless $out;

    local $INPUT_RECORD_SEPARATOR; # Set input to "slurp" mode.
    my $result = <$out>;
    close $out;

    return $result;
}

1;
__END__

=head1 NAME

FusionInventory::Agent::HTTP::Client::GLPI - HTTP client for GLPI server

=head1 DESCRIPTION

This is the object used by the agent to send messages to its control server,
using either legacy OCS protocol (XML messages sent through POST requests) or
new Fusion protocol (JSON messages sent through GET requests).  

=head1 METHODS

=head2 sendJSON(%params)

The following parameters are allowed, as keys of the %params
hash:

=over

=item I<url>

the url to send the message to (mandatory)

=item I<args>

A list of parameters to pass to the server. The action key is mandatory.
Parameters can be hashref or arrayref.

=back

This method returns a perl data structure.

=head2 sendXML(%params)

Send an instance of C<FusionInventory::Agent::Message::Outbound> to a server.

The following parameters are allowed, as keys of the %params
hash:

=over

=item I<url>

the url to send the message to (mandatory)

=item I<message>

the message to send (mandatory)

=back

This method returns a perl data structure.
