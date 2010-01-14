package Business::OnlinePayment::PaymenTech;

use strict;
use Carp;
use Business::OnlinePayment::HTTPS;
use XML::Simple;
use Tie::IxHash;
use vars qw($VERSION $DEBUG @ISA $me);

@ISA = qw(Business::OnlinePayment::HTTPS);
$VERSION = '2.02';
$DEBUG = 0;
$me='Business::OnlinePayment::PaymenTech';

my %request_header = (
  'MIME-VERSION'    =>    '1.0',
  'Content-Transfer-Encoding' => 'text',
  'Request-Number'  =>    1,
  'Document-Type'   =>    'Request',
  'Interface-Version' =>  "$me $VERSION",
); # Content-Type has to be passed separately

tie my %new_order, 'Tie::IxHash', (
  OrbitalConnectionUsername => ':login',
  OrbitalConnectionPassword => ':password',
  IndustryType              => 'EC', # Assume industry = Ecommerce
  MessageType               => ':message_type',
  BIN                       => ':bin',
  MerchantID                => ':merchant_id',
  TerminalID                => ':terminal_id',
  CardBrand                 => '',
  AccountNum                => ':card_number',
  Exp                       => ':expiration',
  CurrencyCode              => ':currency_code',
  CurrencyExponent          => ':currency_exp',
  CardSecValInd             => ':cvvind',
  CardSecVal                => ':cvv2',
  AVSzip                    => ':zip',
  AVSaddress1               => ':address',
  AVScity                   => ':city',
  AVSstate                  => ':state',
  OrderID                   => ':invoice_number',
  Amount                    => ':amount',
  Comments                  => ':email', # as per B:OP:WesternACH
  TxRefNum                  => ':order_number', # used only for Refund
);

tie my %mark_for_capture, 'Tie::IxHash', (
  OrbitalConnectionUsername => ':login',
  OrbitalConnectionPassword => ':password',
  OrderID                   => ':invoice_number',
  Amount                    => ':amount',
  BIN                       => ':bin',
  MerchantID                => ':merchant_id',
  TerminalID                => ':terminal_id',
  TxRefNum                  => ':order_number',
);

tie my %reversal, 'Tie::IxHash', (
  OrbitalConnectionUsername => ':login',
  OrbitalConnectionPassword => ':password',
  TxRefNum                  => ':order_number',
  TxRefIdx                  => 0,
  OrderID                   => ':invoice_number',
  BIN                       => ':bin',
  MerchantID                => ':merchant_id',
  TerminalID                => ':terminal_id',
# Always attempt to reverse authorization.
  OnlineReversalInd         => 'Y',
);

my %defaults = (
  terminal_id => '001',
  currency    => 'USD',
  cvvind      => '',
);

my @required = ( qw(
  login
  password
  action
  bin
  merchant_id
  invoice_number
  amount
  )
);

my %currency_code = (
# Per ISO 4217.  Add to this as needed.
  USD => [840, 2],
  CAD => [124, 2],
  MXN => [484, 2],
);

sub set_defaults {
    my $self = shift;

    $self->server('orbitalvar1.paymentech.net') unless $self->server; # this is the test server.
    $self->port('443') unless $self->port;
    $self->path('/authorize') unless $self->path;

    $self->build_subs(qw( 
      order_number
      ProcStatus 
      ApprovalStatus 
      StatusMsg 
      Response
      RespCode
      AuthCode
      AVSRespCode
      CVV2RespCode
     ));

}

sub build {
  my $self = shift;
  my %content = $self->content();
  my $skel = shift;
  tie my %data, 'Tie::IxHash';
  ref($skel) eq 'HASH' or die 'Tried to build non-hash';
  foreach my $k (keys(%$skel)) {
    my $v = $skel->{$k};
    # Not recursive like B:OP:WesternACH; Paymentech requests are only one layer deep.
    if($v =~ /^:(.*)/) {
      # Get the content field with that name.
      $data{$k} = $content{$1};
    }
    else {
      $data{$k} = $v;
    }
  }
  return \%data;
}

sub map_fields {
    my($self) = @_;

    my %content = $self->content();
    foreach(qw(merchant_id terminal_id currency)) {
      $content{$_} = $self->{$_} if exists($self->{$_});
    }

    $self->required_fields('action');
    my %message_type = 
                  ('normal authorization' => 'AC',
                   'authorization only'   => 'A',
                   'credit'               => 'R',
                   'void'                 => 'V',
                   'post authorization'   => 'MFC', # for our use, doesn't go in the request
                   ); 
    $content{'message_type'} = $message_type{lc($content{'action'})} 
      or die "unsupported action: '".$content{'action'}."'";

    foreach (keys(%defaults) ) {
      $content{$_} = $defaults{$_} if !defined($content{$_});
    }
    if(length($content{merchant_id}) == 12) {
      $content{bin} = '000002' # PNS
    }
    elsif(length($content{merchant_id}) == 6) {
      $content{bin} = '000001' # Salem
    }
    else {
      die "invalid merchant ID: '".$content{merchant_id}."'";
    }

    @content{qw(currency_code currency_exp)} = @{$currency_code{$content{currency}}}
      if $content{currency};

    if($content{card_number} =~ /^(4|6011)/) { # Matches Visa and Discover transactions
      if(defined($content{cvv2})) {
        $content{cvvind} = 1; # "Value is present"
      }
      else {
        $content{cvvind} = 9; # "Value is not available"
      }
    }
    $content{amount} = int($content{amount}*100);
    $content{name} = $content{first_name} . ' ' . $content{last_name};
# According to the spec, the first 8 characters of this have to be unique.
# The test server doesn't enforce this, but we comply anyway to the extent possible.
    if(! $content{invoice_number}) {
      # Choose one arbitrarily
      $content{invoice_number} ||= sprintf("%04x%04x",time % 2**16,int(rand() * 2**16));
    }

    $content{expiration} =~ s/\D//g; # Because Freeside sends it as mm/yy, not mmyy.

    $self->content(%content);
    return;
}

sub submit {
  my($self) = @_;
  $DB::single = $DEBUG;

  $self->map_fields();
  my %content = $self->content;

  my @required_fields = @required;

  my $request;
  if( $content{'message_type'} eq 'MFC' ) {
    $request = { MarkForCapture => $self->build(\%mark_for_capture) };
    push @required_fields, 'order_number';
  }
  elsif( $content{'message_type'} eq 'V' ) {
    $request = { Reversal => $self->build(\%reversal) };
  }
  else { 
    $request = { NewOrder => $self->build(\%new_order) }; 
    push @required_fields, qw(
      card_number
      expiration
      currency
      address
      city
      zip
      );
  }

  $self->required_fields(@required_fields);

  my $post_data = XMLout({ Request => $request }, KeepRoot => 1, NoAttr => 1, NoSort => 1);

  if (!$self->test_transaction()) {
    $self->server('orbital1.paymentech.net');
  }

  warn $post_data if $DEBUG;
  $DB::single = $DEBUG;
  my($page,$server_response,%headers) =
    $self->https_post( { 'Content-Type' => 'application/PTI47', 
                         'headers' => \%request_header } ,
                          $post_data);

  warn $page if $DEBUG;

  my $response;
  my $error = '';
  if ($server_response =~ /200/){
    $response = XMLin($page, KeepRoot => 0);
    $self->Response($response);
    my ($r) = values(%$response);
    foreach(qw(ProcStatus RespCode AuthCode AVSRespCode CVV2RespCode)) {
      if(exists($r->{$_}) and
         !ref($r->{$_})) {
        $self->$_($r->{$_});
      }
    }
    if(!exists($r->{'ProcStatus'})) {
      $error = "Malformed response: '$page'";
      $self->is_success(0);
    }
    elsif( $r->{'ProcStatus'} != 0 or 
          # NewOrders get ApprovalStatus, Reversals don't.
          ( exists($r->{'ApprovalStatus'}) ?
            $r->{'ApprovalStatus'} != 1 :
            $r->{'StatusMsg'} ne 'Approved' )
          ) {
      $error = "Transaction error: '". ($r->{'ProcStatusMsg'} || $r->{'StatusMsg'}) . "'";
      $self->is_success(0);
    }
    else {
      # success!
      $self->is_success(1);
      # For credits, AuthCode is empty and gets converted to a hashref.
      $self->authorization($r->{'AuthCode'}) if !ref($r->{'AuthCode'});
      $self->order_number($r->{'TxRefNum'});
    }
  } else {
    $error = "Server error: '$server_response'";
  }
  $self->error_message($error);
}

1;
__END__

=head1 NAME

Business::OnlinePayment::PaymenTech - Chase Paymentech backend for Business::OnlinePayment

=head1 SYNOPSIS

$trans = new Business::OnlinePayment('PaymenTech');
$trans->content(
  login           => "login",
  password        => "password",
  merchant_id     => "000111222333",
  terminal_id     => "001",
  type            => "CC",
  card_number     => "5500000000000004",
  expiration      => "0211",
  address         => "123 Anystreet",
  city            => "Sacramento",
  zip             => "95824",
  action          => "Normal Authorization",
  amount          => "24.99",

);

$trans->submit;
if($trans->is_approved) {
  print "Approved: ".$trans->authorization;

} else {
  print "Failed: ".$trans->error_message;

}

=head1 NOTES

The only supported transaction types are Normal Authorization and Credit.  Paymentech 
supports separate Authorize and Capture actions as well as recurring billing, but 
those are not yet implemented.

Electronic check processing is not yet supported.

=head1 AUTHOR

Mark Wells, mark@freeside.biz

=head1 SEE ALSO

perl(1). L<Business::OnlinePayment>.

=cut

