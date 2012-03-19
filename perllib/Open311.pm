package Open311;

use URI;
use Moose;
use XML::Simple;
use LWP::Simple;
use LWP::UserAgent;
use HTTP::Request::Common qw(POST);

has jurisdiction => ( is => 'ro', isa => 'Str' );;
has api_key => ( is => 'ro', isa => 'Str' );
has endpoint => ( is => 'ro', isa => 'Str' );
has test_mode => ( is => 'ro', isa => 'Bool' );
has test_uri_used => ( is => 'rw', 'isa' => 'Str' );
has test_get_returns => ( is => 'rw' );
has endpoints => ( is => 'rw', default => sub { { services => 'services.xml', requests => 'requests.xml', service_request_updates => 'update.xml' } } );
has debug => ( is => 'ro', isa => 'Bool', default => 0 );
has debug_details => ( is => 'rw', 'isa' => 'Str', default => '' );

sub get_service_list {
    my $self = shift;

    my $service_list_xml = $self->_get( $self->endpoints->{services} );

    return $self->_get_xml_object( $service_list_xml );
}

sub get_service_meta_info {
    my $self = shift;
    my $service_id = shift;

    my $service_meta_xml = $self->_get( "services/$service_id.xml" );
    return $self->_get_xml_object( $service_meta_xml );
}

sub send_service_request {
    my $self = shift;
    my $problem = shift;
    my $extra = shift;
    my $service_code = shift;

    my $description = <<EOT;
title:  @{[$problem->title()]}

detail: @{[$problem->detail()]}

url: $extra->{url}

Submitted via FixMyStreet
EOT
;

    my ( $firstname, $lastname ) = ( $problem->user->name =~ /(\w+)\s+(.+)/ );

    my $params = {
        lat => $problem->latitude,
        long => $problem->longitude,
        email => $problem->user->email,
        description => $description,
        service_code => $service_code,
        first_name => $firstname,
        last_name => $lastname || '',
    };

    if ( $problem->user->phone ) {
        $params->{ phone } = $problem->user->phone;
    }

    if ( $extra->{image_url} ) {
        $params->{media_url} = $extra->{image_url};
    }

    if ( $problem->extra ) {
        my $extras = $problem->extra;

        for my $attr ( @$extras ) {
            my $name = sprintf( 'attribute[%s]', $attr->{name} );
            $params->{ $name } = $attr->{value};
        }
    }

    my $response = $self->_post( $self->endpoints->{requests}, $params );

    if ( $response ) {
        my $obj = $self->_get_xml_object( $response );

        if ( $obj ) {
            if ( $obj->{ request }->{ service_request_id } ) {
                return $obj->{ request }->{ service_request_id };
            } else {
                my $token = $obj->{ request }->{ token };
                if ( $token ) {
                    return $self->get_service_request_id_from_token( $token );
                }
            }
        }

        warn sprintf( "Failed to submit problem %s over Open311, response\n: %s\n%s", $problem->id, $response, $self->debug_details );
        return 0;
    }
}

sub get_service_requests {
    my $self = shift;
    my $report_ids = shift;

    my $params = {};

    if ( $report_ids ) {
        $params->{service_request_id} = join ',', @$report_ids;
    }

    my $service_request_xml = $self->_get( $self->endpoints->{requests}, $params || undef );
    return $self->_get_xml_object( $service_request_xml );
}

sub get_service_request_id_from_token {
    my $self = shift;
    my $token = shift;

    my $service_token_xml = $self->_get( "tokens/$token.xml" );

    my $obj = $self->_get_xml_object( $service_token_xml );

    if ( $obj && $obj->{ request }->{ service_request_id } ) {
        return $obj->{ request }->{ service_request_id };
    } else {
        return 0;
    }
}

sub get_service_request_updates {
    my $self = shift;

    my $params = {};

    my $xml = $self->_get( $self->endpoints->{service_request_updates}, $params || undef );
    return $self->_get_xml_object( $xml );
}

sub _get {
    my $self   = shift;
    my $path   = shift;
    my $params = shift || {};

    my $uri = URI->new( $self->endpoint );

    $params->{ jurisdiction_id } = $self->jurisdiction;
    $uri->path( $uri->path . $path );
    $uri->query_form( $params );

    $self->debug_details( $self->debug_details . "\nrequest:" . $uri->as_string );

    my $content;
    if ( $self->test_mode ) {
        $content = $self->test_get_returns->{ $path };
        $self->test_uri_used( $uri->as_string );
    } else {
        $content = get( $uri->as_string );
    }

    return $content;
}

sub _post {
    my $self = shift;
    my $path   = shift;
    my $params = shift;

    my $uri = URI->new( $self->endpoint );
    $uri->path( $uri->path . $path );

    my $req = POST $uri->as_string,
    [
        jurisdiction_id => $self->jurisdiction,
        api_key => $self->api_key,
        %{ $params }
    ];

    $self->debug_details( $self->debug_details . "\nrequest:" . $req->as_string );

    my $ua = LWP::UserAgent->new();
    my $res = $ua->request( $req );

    if ( $res->is_success ) {
        return $res->decoded_content;
    } else {
        warn sprintf( 
            "request failed: %s\nerror: %s\n%s",
            $res->status_line,
            $self->_process_error( $res->decoded_content ),
            $self->debug_details
        );
        return 0;
    }
}

sub _process_error {
    my $self = shift;
    my $error = shift;

    my $obj = $self->_get_xml_object( $error );

    my $msg = '';
    if ( ref $obj && exists $obj->{error} ) {
        my $errors = $obj->{error};
        $errors = [ $errors ] if ref $errors ne 'ARRAY';
        $msg .= sprintf( "%s: %s\n", $_->{code}, $_->{description} ) for @{ $errors };
    }

    return $msg || 'unknown error';
}

sub _get_xml_object {
    my $self = shift;
    my $xml= shift;

    my $simple = XML::Simple->new();
    my $obj;

    eval {
        $obj = $simple ->XMLin( $xml );
    };

    return $obj;
}
1;
