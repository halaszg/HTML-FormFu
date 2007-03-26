package HTML::FormFu;
use strict;
use warnings;
use base 'Class::Accessor::Chained::Fast';

use HTML::FormFu::Accessor qw/ mk_inherited_accessors mk_output_accessors /;
use HTML::FormFu::Attribute qw/ 
    mk_attrs mk_attr_accessors mk_add_methods mk_single_methods 
    mk_require_methods mk_get_methods mk_get_one_methods /;
use HTML::FormFu::Constraint;
use HTML::FormFu::Exception;
use HTML::FormFu::FakeQuery;
use HTML::FormFu::Filter;
use HTML::FormFu::Inflator;
use HTML::FormFu::Localize;
use HTML::FormFu::ObjectUtil qw/ 
    _single_element _require_constraint 
    get_elements get_element get_all_elements get_fields get_field 
    get_errors get_error delete_errors
    populate load_config_file insert_before insert_after form
    _render_class clone stash /;
use HTML::FormFu::Util qw/ _parse_args require_class _get_elements xml_escape /;
use List::MoreUtils qw/ uniq /;
use Scalar::Util qw/ blessed weaken /;
use Storable qw/ dclone /;
use Regexp::Copy;
use Carp qw/ croak /;

use overload
    '""' => sub { return shift->render },
    bool => sub {1};

__PACKAGE__->mk_attrs(qw/ attributes /);

__PACKAGE__->mk_attr_accessors(qw/ id action enctype method /);

__PACKAGE__->mk_accessors(
    qw/ parent
        indicator filename javascript
        element_defaults query_type languages
        localize_class submitted query input _auto_fieldset
        _elements _processed_params _valid_names /
);

__PACKAGE__->mk_output_accessors(qw/ form_error_message /);

__PACKAGE__->mk_inherited_accessors(
    qw/ auto_id auto_label auto_error_class auto_error_message
    auto_constraint_class auto_inflator_class auto_validator_class 
    auto_transformer_class
    render_class render_class_prefix render_class_suffix render_class_args 
    render_method /
);

__PACKAGE__->mk_add_methods(qw/ 
    element deflator filter constraint inflator validator transformer /);

__PACKAGE__->mk_single_methods(qw/ 
    deflator filter constraint inflator validator transformer /);

__PACKAGE__->mk_require_methods(qw/ 
    deflator filter inflator validator transformer /);

__PACKAGE__->mk_get_methods(qw/ 
    deflator filter constraint inflator validator transformer /);

__PACKAGE__->mk_get_one_methods(qw/ 
    deflator filter constraint inflator validator tranformer /);

*elements     = \&element;
*constraints  = \&constraint;
*filters      = \&filter;
*deflators    = \&deflator;
*inflators    = \&inflator;
*validators   = \&validator;
*transformers = \&transformer;
*loc          = \&localize;

our $VERSION = '0.00_01';

sub new {
    my $class = shift;

    my %attrs;
    eval { %attrs = %{ $_[0] } if @_ };
    croak "attributes argument must be a hashref" if $@;

    my $self = bless {}, $class;
    
    my %defaults = (
        _elements           => [],
        _valid_names        => [],
        _processed_params   => {},
        input               => {},
        stash               => {},
        action              => '',
        method              => 'post',
        render_class_prefix => 'HTML::FormFu::Render',
        render_class_suffix => 'Form',
        render_class_args   => {},
        filename            => 'form',
        element_defaults    => {},
        render_method       => 'xhtml',
        query_type          => 'CGI',
        languages           => ['en'],
        localize_class      => 'HTML::FormFu::I18N',
        auto_error_class    => 'error_%s_%t',
        auto_error_message  => 'form_%t_error',
    );

    $self->populate( \%defaults );

    $self->populate( \%attrs );

    return $self;
}

sub auto_fieldset {
    my $self = shift;
    
    return $self->_auto_fieldset if !@_;
    
    my %opts = ref $_[0] ? %{$_[0]} : ();
    
    $opts{type} = 'fieldset';
    
    $self->element( \%opts );
    
    $self->_auto_fieldset(1);
    
    return $self;
}

sub process {
    my $self = shift;

    $self->input(             {} );
    $self->_processed_params( {} );
    $self->_valid_names(      [] );
    $self->delete_errors;

    my $query;
    if (@_) {
        $query = shift;
        $self->query($query);
    }
    else {
        $query = $self->query;
    }
    my $submitted;
    my @params;

    if ( defined $query ) {
        $query = HTML::FormFu::FakeQuery->new($query)
            if !blessed($query);

        eval { @params = $query->param };
        croak "Invalid query object: $@" if $@;

        $submitted = $self->_submitted($query);
    }
    
    $self->submitted( $submitted );
    
    return if !$submitted;

    my %params;

    for my $param ( $query->param ) {

        # don't allow names without a matching field
        next unless $self->get_field($param);

        my @values = $query->param($param);
        $params{$param} = @values > 1 ? \@values : $values[0];
    }
        ### constraints
        #    my $render = $constraint->render_errors;
        #    my @render =
        #          ref $render     ? @{$render}
        #        : defined $render ? $render
        #        :                   ();
        #        $result->no_render(1)
        #            if @render && !grep { $name eq $_ } @render;
    
    $self->input( \%params );
    
    $self->_process_input;
    
    return;
}

sub _submitted {
    my ( $self, $query ) = @_;

    my $indi = $self->indicator;
    my $code;

    if ( defined($indi) && ref $indi ne 'CODE' ) {
        $code = sub { return defined $query->param($indi) };
    }
    elsif ( !defined $indi ) {
        my @names = uniq(
            map      { $_->name }
                grep { defined $_->name } @{ $self->get_fields }
        );

        $code = sub {
            grep { defined $query->param($_) } @names;
        };
    }
    else {
        $code = $indi;
    }

    return $code->( $self, $query );
}

sub _process_input {
    my ($self) = @_;

    $self->_build_params;
    
    $self->_process_file_uploads;
    
    $self->_filter_input;
    
    $self->_constrain_input;
    
    $self->_inflate_input
        if !@{ $self->get_errors };
    
    $self->_validate_input
        if !@{ $self->get_errors };
    
    $self->_transform_input
        if !@{ $self->get_errors };
    
    $self->_build_valid_names;
    
    return;
}

sub _build_params {
    my ($self) = @_;

    my $input = $self->input;
    my %params;
    
    my @names = uniq(
        sort
        map { $_->name }
        grep { defined $_->name }
        @{ $self->get_fields }
        );
    
    for my $name (@names) {
        my $input = exists $input->{$name} ? $input->{$name} : undef;
        
        if ( ref $input eq 'ARRAY' ) {
            # can't clone upload filehandles
            # so create new arrayref of values
            $input = [@$input];
        }
        
        $params{$name} = $input;
    }

    $self->_processed_params( \%params );
    
    return;
}

sub _process_file_uploads {
    my ($self) = @_;
    
    my @names = uniq(
        sort
        map { $_->name }
        grep { $_->isa('HTML::FormFu::Element::file') }
        grep { defined $_->name }
        @{ $self->get_fields }
        );

    if (@names) {
        my $query_class = $self->query_type;
        if ( $query_class !~ /^\+/ ) {
            $query_class = "HTML::FormFu::QueryType::$query_class";
        }
        require_class($query_class);
        
        my $params = $self->_processed_params;
    
        for my $name (@names) {
            
            my $values = $query_class->parse_uploads( $self, $name );
            
            $params->{$name} = $values;
        }
    }

    return;
}

sub _filter_input {
    my ($self) = @_;

    for my $filter ( map { @{ $_->get_filters } } @{ $self->_elements } ) {
        $filter->process( $self, $self->_processed_params );
    }
    
    return;
}

sub _constrain_input {
    my ($self) = @_;
    
    my $params = $self->_processed_params;

    for my $constraint ( map { @{ $_->get_constraints } } @{ $self->_elements } )
    {
        my @errors = eval {
            $constraint->process( $params );
            };
        if ( blessed $@ && $@->isa('HTML::FormFu::Exception::Constraint') ) {
            push @errors, $@;
        }
        elsif ( $@ ) {
            push @errors, HTML::FormFu::Exception::Constraint->new;
        }
        
        for my $error (@errors) {
            $error->parent( $constraint->parent ) if !$error->parent;
            $error->constraint( $constraint )     if !$error->constraint;
            
            $error->parent->add_error( $error );
        }
    }

    return;
}

sub _inflate_input {
    my ($self) = @_;

    for my $name ( keys %{ $self->_processed_params } ) {
        my $value = $self->_processed_params->{$name};

        for my $inflator ( map { @{ $_->get_inflators( { name => $name } ) } }
            @{ $self->_elements } )
        {
            my @errors;
            
            ( $value, @errors ) = eval {
                $inflator->process($value);
                };
            if ( blessed $@ && $@->isa('HTML::FormFu::Exception::Inflator') ) {
                push @errors, $@;
            }
            elsif ( $@ ) {
                push @errors, HTML::FormFu::Exception::Inflator->new;
            }
            
            for my $error (@errors) {
                $error->parent( $inflator->parent ) if !$error->parent;
                $error->inflator( $inflator )       if !$error->inflator;
                
                $error->parent->add_error( $error );
            }
        }
        
        $self->_processed_params->{$name} = $value
            if !@{ $self->get_errors({ name => $name }) };
    }

    return;
}

sub _validate_input {
    my ($self) = @_;
    
    my $params = $self->_processed_params;

    for my $validator ( map { @{ $_->get_validators } } @{ $self->_elements } )
    {
        my @errors = eval {
            $validator->process( $params );
            };
        if ( blessed $@ && $@->isa('HTML::FormFu::Exception::Validator') ) {
            push @errors, $@;
        }
        elsif ( $@ ) {
            push @errors, HTML::FormFu::Exception::Validator->new;
        }
        
        for my $error (@errors) {
            $error->parent( $validator->parent ) if !$error->parent;
            $error->validator( $validator )     if !$error->validator;
            
            $error->parent->add_error( $error );
        }
    }
    
    return;
}

sub _transform_input {
    my ($self) = @_;

    for my $name ( keys %{ $self->_processed_params } ) {
        my $value = $self->_processed_params->{$name};

        for my $transformer ( map { @{ $_->get_transformers( { name => $name } ) } }
            @{ $self->_elements } )
        {
            my @errors;
            
            ( $value, @errors ) = eval {
                $transformer->process($value);
                };
            if ( blessed $@ && $@->isa('HTML::FormFu::Exception::Transformer') ) {
                push @errors, $@;
            }
            elsif ( $@ ) {
                push @errors, HTML::FormFu::Exception::Transformer->new;
            }
            
            for my $error (@errors) {
                $error->parent( $transformer->parent ) if !$error->parent;
                $error->transformer( $transformer )    if !$error->transformer;
                
                $error->parent->add_error( $error );
            }
        }
        
        $self->_processed_params->{$name} = $value
            if !@{ $self->get_errors({ name => $name }) };
    }

    return;
}

sub _build_valid_names {
    my ($self) = @_;

    my @errors = $self->has_errors;
    my @names  = keys %{ $self->input };

    my %valid;
CHECK: for my $name (@names) {
        for my $error (@errors) {
            next CHECK if $name eq $error;
        }
        $valid{$name}++;
    }
    my @valid = keys %valid;

    $self->_valid_names( \@valid );

    return;
}

sub submitted_and_valid {
    my ($self) = @_;
    
    return $self->submitted && !$self->has_errors;
}

sub params {
    my ($self) = @_;

    my @names = $self->valid;
    my %params;

    for my $name (@names) {
        my @values = $self->param($name);
        if ( @values > 1 ) {
            $params{$name} = \@values;
        }
        else {
            $params{$name} = $values[0];
        }
    }

    return \%params;
}

sub param {
    my $self = shift;

    croak 'param method is readonly' if @_ > 1;

    if ( @_ == 1 ) {

        # only return a valid value
        my $name  = shift;
        my $valid = $self->valid($name);
        my $value = $self->_processed_params->{$name};

        if ( !defined $valid || !defined $value ) {
            return;
        }

        if ( ref $value eq 'ARRAY' ) {
            return wantarray ? @$value : $value->[0];
        }
        else {
            return $value;
        }
    }

    # return a list of valid names, if no $name arg
    return $self->valid;
}

sub valid {
    my $self  = shift;
    my @valid = @{ $self->_valid_names };

    if (@_) {
        my $name = shift;
        return 1 if grep {/\Q$name/} @valid;
        return;
    }

    # return a list of valid names, if no $name arg
    return @valid;
}

sub has_errors {
    my $self = shift;

    return if !$self->submitted;

    my @names = map { $_->name }
        grep { @{ $_->get_errors } }
        grep { defined $_->name }
        @{ $self->get_fields };

    if (@_) {
        my $name = shift;
        return 1 if grep {/\Q$name/} @names;
        return;
    }

    # return list of names with errors, if no $name arg
    return @names;
}

sub add_valid {
    my ( $self, $key, $value ) = @_;

    croak 'add_valid requires arguments ($key, $value)' unless @_ == 3;

    $self->input->{$key} = $value;

    $self->_processed_params->{$key} = $value;
    
    push @{ $self->_valid_names }, $key
        if !grep { $_ eq $key } @{ $self->_valid_names };

    return $value;
}

sub render {
    my ($self) = @_;

    my $class = $self->_render_class;
    require_class($class);

    my $render = $class->new( {
            render_class_args   => $self->render_class_args,
            render_class_suffix => $self->render_class_suffix,
            render_method       => $self->render_method,
            filename            => $self->filename,
            javascript          => $self->javascript,
            form_error_message  => xml_escape( $self->form_error_message ),
            _elements           => [ map { $_->render } @{ $self->_elements } ],
            parent              => $self,
        } );

    $render->attributes( xml_escape $self->attributes );
    $render->stash( $self->stash );

    return $render;
}

sub start_form {
    return shift->render->start_form;
}

sub end_form {
    return shift->render->end_form;
}

sub hidden_fields {
    my ($self) = @_;

    return join "", map { $_->render } 
        @{ $self->get_fields( { type => 'hidden' } ) };
}

1;

__END__

=head1 NAME

HTML::FormFu - HTML Form Creation, Rendering and Validation Framework

=head1 SYNOPSIS

    use HTML::FormFu;

    my $form = HTML::FormFu->new;
    
    $form->load_config_file('form.yml');

    $form->process( $cgi_query );

    if ( $form->submitted_and_valid ) {
        # do something with $form->params
    }
    else {
    	# display the form
        $template->param( form => $form );
    }

Here's an example of a config file to create a basic login form (all examples 
here are L<YAML>, but you can use any format supported by L<Config::Any>).

    ---
    action: /login
    indicator: user
    auto_fieldset: 1
    elements:
      - type: text
        name: user
        constraints: 
          - Required
      - type: password
        name: pass
        constraints:
          - Required
      - type: submit

=head1 DESCRIPTION

L<HTML::FormFu> is a HTML form framework which aims to be as easy as 
possible to use for basic web forms, but with the power and flexibility to 
do anything else you might want to do (as long as it involves forms).

You can configure almost any part of formfu's behaviour and output. By 
default formfu renders "XHTML 1.0 Strict" complient markup, with as little 
extra markup as possible, but with sufficient CSS class names to allow for a 
wide-range of output styles to be generated by changing only the CSS.

All methods listed below (except L</new> can either be called as a normal 
method on your <code>$form</code> object, or as an option in your config 
file. Examples will mainly be shown in L<YAML> config syntax.

This documentation follows the convention that method arguments surrounded 
by square brackets C<[]> are I<optional>, and all other arguments are 
required.

=head1 BUILDING A FORM

=head2 new

Arguments: [\%options]

Return Value: $form

Create a new L<HTML::FormFu|HTML::FormFu> object.

Any method which can be called on the L<HTML::FormFu|HTML::FormFu> object may 
instead be passed as an argument to L</new>.

    my $form = HTML::FormFu->new({
        action        => '/search',
        method        => 'GET',
        auto_fieldset => 1,
    });

=head2 load_config_file

Arguments: $filename

Arguments: \@filenames

Return Value: $form

Accepts a filename or list of file names, whose filetypes should be of any 
format recognized by L<Config::Any>.

The content of each config file is passed to L</populate>, and so are added 
to the form.

L</load_config_file> may be called in a config file itself, as so allow 
common settings to be kept in a single config file which may be loaded 
by any form.

See L</BEST PRACTICES> for advice on organising config files.

=head2 populate

Arguments: \%options

Return Value: $form

Each option key/value passed may be any L<HTML::FormFu|HTML::FormFu> 
method-name and arguments.

Provides a simple way to set multiple values, or add multiple elements to 
a form with a single method-call.

=head2 indicator

Arguments: $field_name

Arguments: \&coderef

If L</indicator> is set to a fieldname, L</submitted> will return true if 
a value for that fieldname was submitted.

If L</indicator> is set to a code-ref, it will be called as a subroutine 
with the two arguments C<$form> and C<$query>, and it's return value will be 
used as the return value for L</submitted>.

If L</indicator> is not set, </submitted> will return true if a value for 
any known fieldname was submitted.

=head2 auto_fieldset

Arguments: 1

Arguments: \%options

Return Value: $fieldset

This setting is suitable for most basic forms, and means you can generally
ignore adding fieldsets yourself.

Calling C<< $form->auto_fieldset(1) >> immediately adds a fieldset element to 
the form. Thereafter, C<< $form->elements() >> will add all elements (except 
fieldsets) to that fieldset, rather than directly to the form.

To be specific, the elements are added to the L<last> fieldset on the form, 
so if you add another fieldset, any further elements will be added to that 
fieldset.

Also, you may pass a hashref to auto_fieldset(), and this will be used
to set defaults for the first fieldset created.

A few examples and their output, to demonstrate:

2 elements with no fieldset.

    ---
    elements:
      - type: text
        name: foo
      - type: text
        name: bar

    <form action="" method="post">
      <span class="text">
        <input name="foo" type="text" />
      </span>
      <span class="text">
        <input name="bar" type="text" />
      </span>
    </form>

2 elements with an L</auto_fieldset>.

    ---
    auto_fieldset: 1
    elements:
      - type: text
        name: foo
      - type: text
        name: bar

    <form action="" method="post">
      <fieldset>
        <span class="text">
          <input name="foo" type="text" />
        </span>
        <span class="text">
          <input name="bar" type="text" />
        </span>
      </fieldset>
    </form>

The 3rd element is within a new fieldset

    ---
    auto_fieldset: { id: fs }
    elements:
      - type: text
        name: foo
      - type: text
        name: bar
      - type: fieldset
      - type: text
        name: baz

    <form action="" method="post">
      <fieldset id="fs">
        <span class="text">
          <input name="foo" type="text" />
        </span>
        <span class="text">
          <input name="bar" type="text" />
        </span>
      </fieldset>
      <fieldset>
        <span class="text">
          <input name="baz" type="text" />
        </span>
      </fieldset>
    </form>

Because of this behaviour, if you want nested fieldsets you will have to add 
each nested fieldset directly to it's intended parent.

    my $parent = $form->get_element({ type => 'fieldset' });
    
    $parent->element('fieldset');

=head2 form_error_message

Arguments: $string

Normally, input errors cause an error message to be displayed alongside the 
appropriate form field. If you'd also like a general error message to be 
displayed at the top of the form, you can set the message with 
L</form_error_message>.

To change the markup used to display the message, edit the 
C<form_error_message> template file.

=head2 form_error_message_xml

Arguments: $string

If you don't want your error message to be XML-escaped, use the 
L</form_error_message_xml> method instead.

=head2 form_error_message_loc

Arguments: $localization_key

For ease of use, if you'd like to use the provided localized error message, 
set L</form_error_message_loc> to the value C<form_error_message>.

You can, of course, set L</form_error_message_loc> to any key in your L10N 
file.

=head2 element_defaults

Arguments: \%defaults

Set defaults which will be added to every element of that type which is added 
to the form.

For example, to make every C<text> element automatically have a 
L<size|HTML::FormFu::Element/size> of C<10>, and make every C<textarea> 
element automatically get a class-name of C<bigbox>:

    element_defaults:
      text:
        size: 10
      textarea:
        add_attributes:
          class: bigbox

=head2 javascript

Arguments: $javascript

If set, the contents will be rendered within a C<script> tag, inside the top 
of the form.

=head2 stash

Arguments: \%private_stash

Provides a hash-ref in which you can store any data you might want to 
associate with the form. This data will not be used by 
L<HTML::FormFu|HTML::FormFu> at all.

=head2 elements

=head2 element

Arguments: $type

Arguments: \%options

Return Value: $element

Arguments: \@arrayref_of_types_or_options

Return Value: @elements

Adds a new element to the form. See L<HTML::FormFu::Element> for a list of 
core elements.

If you want to load an element from a namespace other than 
C<HTML::FormFu::Element::>, you can use a fully qualified package-name by 
prefixing it with C<+>.

    ---
    elements:
      - type: +MyApp::CustomElement
        name: foo

If a C<type> is not provided in the C<\%options>, the default C<text> will 
be used.

L</element> is an alias for L</elements>.

=head2 deflators

=head2 deflator

Arguments: $type

Arguments: \%options

Return Value: $deflator

Arguments: \@arrayref_of_types_or_options

Return Value: @deflators

A L<deflator|HTML::FormFu::Deflator> may be associated with any form field, 
and allows you to provide 
L<< $field->default|HTML:FormFu::Element::field/default >> with a value 
which may be an object.

If an object doesn't stringify to a suitable value for display, the 
L<deflator|HTML::FormFu::Deflator> can ensure that the form field 
receives a suitable string value instead.

See L<HTML::FormFu::Deflator> for a list of core deflators.

If you want to load a filter in a namespace other than 
C<HTML::FormFu::Deflator::>, you can use a fully qualified package-name by 
prefixing it with C<+>.

L</deflator> is an alias for L</deflators>.

=head1 FORM LOGIC AND VALIDATION

L<HTML::FormFu|HTML::FormFu> provides several stages for what is 
traditionally described as I<validation>. These are:

=over

=item L<HTML::FormFu::Filter|HTML::FormFu::Filter>

=item L<HTML::FormFu::Constraint|HTML::FormFu::Constraint>

=item L<HTML::FormFu::Inflator|HTML::FormFu::Inflator>

=item L<HTML::FormFu::Validator|HTML::FormFu::Validator>

=item L<HTML::FormFu::Transformer|HTML::FormFu::Transformer>

=back

The first stage, the filters, allow for cleanup of user-input, such as 
encoding, or removing leading/trailing whitespace, or removing non-digit 
characters from a creditcard number.

All of the following stages allow for more complex processing, and each of 
them have a mechanism to allow exceptions to be thrown, to represent input 
errors. In each stage, all form fields must be processed without error for 
the next stage to proceed. If there were any errors, the form should be 
re-displayed to the user, to allow them to input correct values.

Constraints are intended for low-level validation of values, such as 
"is this value within bounds" or "is this a valid email address".

Inflators are intended to allow a value to be turned into an appropriate 
object. The resulting object will be passed to subsequent Validators and 
Transformers, and will also be returned by L</params> and L</param>.

Validators allow for a more complex validation than Constraints. Validators 
can be sure that all values have successfully passed all Constraints and have 
been successfully passed through all Inflators. It is expected that most 
Validators will be application-specific, and so each will be implemented as 
a seperate class written by the L<HTML::FormFu|HTML::FormFu> user.

=head2 filters

=head2 filter

Arguments: $type

Arguments: \%options

Return Value: $filter

Arguments: \@arrayref_of_types_or_options

Return Value: @filters

If you provide a C<name> or C<names> value, the filter will be added to 
just that named field.
If you do not provide a C<name> or C<names> value, the filter will be added 
to all L<fields|HTML::FormFu::Element::field> already attached to the form. 

See L<HTML::FormFu::Filter> for a list of core filters.

If you want to load a filter in a namespace other than 
C<HTML::FormFu::Filter::>, you can use a fully qualified package-name by 
prefixing it with C<+>.

L</filter> is an alias for L</filters>.

=head2 constraints

=head2 constraint

Arguments: $type

Arguments: \%options

Return Value: $constraint

Arguments: \@arrayref_of_types_or_options

Return Value: @constraints

See L<HTML::FormFu::Constraint> for a list of core constraints.

If you want to load a constraint in a namespace other than 
C<HTML::FormFu::Constraint::>, you can use a fully qualified package-name by 
prefixing it with C<+>.

L</constraint> is an alias for L</constraints>.

=head2 inflators

=head2 inflator

Arguments: $type

Arguments: \%options

Return Value: $inflator

Arguments: \@arrayref_of_types_or_options

Return Value: @inflators

See L<HTML::FormFu::Inflator> for a list of core inflators.

If you want to load a inflator in a namespace other than 
C<HTML::FormFu::Inflator::>, you can use a fully qualified package-name by 
prefixing it with C<+>.

L</inflator> is an alias for L</inflators>.

=head2 validators

=head2 validator

Arguments: $type

Arguments: \%options

Return Value: $validator

Arguments: \@arrayref_of_types_or_options

Return Value: @validators

See L<HTML::FormFu::Validator> for a list of core validators.

If you want to load a validator in a namespace other than 
C<HTML::FormFu::Validator::>, you can use a fully qualified package-name by 
prefixing it with C<+>.

L</validator> is an alias for L</validators>.

=head2 transformers

=head2 transformer

Arguments: $type

Arguments: \%options

Return Value: $transformer

Arguments: \@arrayref_of_types_or_options

Return Value: @transformers

See L<HTML::FormFu::Transformer> for a list of core transformer.

If you want to load a transformer in a namespace other than 
C<HTML::FormFu::Transformer::>, you can use a fully qualified package-name by 
prefixing it with C<+>.

L</transformer> is an alias for L</transformers>.

=head1 FORM ATTRIBUTES

All attributes are added to the rendered form's start tag.

=head2 attributes

=head2 attrs

Arguments: [%attributes]

Arguments: [\%attributes]

Return Value: $form

Accepts either a list of key/value pairs, or a hash-ref.

    ---
    attributes:
      id: form
      class: fancy_form

As a special case, if no arguments are passed, the attributes hash-ref is 
returned. This allows the following idioms.

    # set a value
    $form->attributes->{id} = 'form';
    
    # delete all attributes
    %{ $form->attributes } = ();

L</attrs> is an alias for L</attributes>.

=head2 attributes_xml

=head2 attrs_xml

Provides the same functionality as L<"/attributes">, but values won't be 
XML-escaped.

L</attrs_xml> is an alias for L</attributes_xml>.

=head2 add_attributes

=head2 add_attrs

Arguments: [%attributes]

Arguments: [\%attributes]

Return Value: $form

Accepts either a list of key/value pairs, or a hash-ref.

    $form->add_attributes( $key => $value );
    $form->add_attributes( { $key => $value } );

All values are appended to existing values, with a preceeding space 
character. This is primarily to allow the easy addition of new class names.

    $form->attributes({ class => 'foo' });
    
    $form->add_attributes({ class => 'bar' });
    
    # class is now 'foo bar'

L</add_attrs> is an alias for L</add_attributes>.

=head2 add_attributes_xml

=head2 add_attrs_xml

Provides the same functionality as L<"/add_attributes">, but values won't be 
XML-escaped.

L</add_attrs_xml> is an alias for L</add_attributes_xml>.

The following methods are shortcuts for accessing L<"/attributes"> keys.

=head2 id

Arguments: [$id]

Return Value: $id

Get or set the form's DOM id.

Default Value: none

=head2 action

Arguments: [$uri]

Return Value: $uri

Get or set the action associated with the form. The default is no action,  
which causes most browsers to submit to the current URI.

Default Value: ""

=head2 enctype

Arguments: [$enctype]

Return Value: $enctype

Get or set the encoding type of the form. Valid values are 
C<application/x-www-form-urlencoded> and C<multipart/form-data>.

If the form contains a File element, the enctype is automatically set to
C<multipart/form-data>.

=head2 method

Arguments: [$method]

Return Value: $method

Get or set the method used to submit the form. Can be set to either "post" 
or "get".

Default Value: "post"

=head1 CSS CLASSES

=head2 auto_id

Arguments: $string

If set, then all form fields will be given an auto-generated 
L<id|HTML::FormFu::Element/id> attribute, if it doesn't have one already.

The following character substitution will be performed: C<%f> will be 
replaced by L<< $form->id|/id >>, C<%n> will be replaced by 
L<< $field->name|HTML::FormFu::Element/name >>.

Default Value: not defined

This method is a special 'inherited accessor', which means it can be set on 
the form, a block element or a single element. When the value is read, if 
no value is defined it automatically traverses the element's hierarchy of 
parents, through any block elements and up to the form, searching for a 
defined value.

=head2 auto_label

Arguments: $string

If set, then all form fields will be given an auto-generated 
L<name|HTML::FormFu::Element::field/label>, if it doesn't have one already.

The following character substitution will be performed: C<%f> will be 
replaced by L<< $form->id|/id >>, C<%n> will be replaced by 
L<< $field->name|HTML::FormFu::Element/name >>.

The generated string will be passed to L</localize> to create the label.

Default Value: not defined

This method is a special 'inherited accessor', which means it can be set on 
the form, a block element or a single element. When the value is read, if 
no value is defined it automatically traverses the element's hierarchy of 
parents, through any block elements and up to the form, searching for a 
defined value.

=head2 auto_error_class

Arguments: $string

If set, then all form errors will be given an auto-generated class-name.

The following character substitution will be performed: C<%f> will be 
replaced by L<< $form->id|/id >>, C<%n> will be replaced by 
L<< $field->name|HTML::FormFu::Element/name >>, C<%t> will be replaced by 
L<< lc( $field->type )|HTML::FormFu::Element/type >>, C<%s> will be replaced 
by L<< $error->stage >>.

Default Value: 'error_%s_%t'

This method is a special 'inherited accessor', which means it can be set on 
the form, a block element or a single element. When the value is read, if 
no value is defined it automatically traverses the element's hierarchy of 
parents, through any block elements and up to the form, searching for a 
defined value.

=head2 auto_error_message

Arguments: $string

If set, then all form fields will be given an auto-generated 
L<message|HTML::FormFu::Exception::Input/message>, if it doesn't have one 
already.

The following character substitution will be performed: C<%f> will be 
replaced by L<< $form->id|/id >>, C<%n> will be replaced by 
L<< $field->name|HTML::FormFu::Element/name >>, C<%t> will be replaced by 
L<< lc( $field->type )|HTML::FormFu::Element/type >>.

The generated string will be passed to L</localize> to create the message.

Default Value: 'form_%t_error'

This method is a special 'inherited accessor', which means it can be set on 
the form, a block element or a single element. When the value is read, if 
no value is defined it automatically traverses the element's hierarchy of 
parents, through any block elements and up to the form, searching for a 
defined value.

=head2 auto_constraint_class

Arguments: $string

If set, then all form fields will be given an auto-generated class-name 
for each associated constraint.

The following character substitution will be performed: C<%f> will be 
replaced by L<< $form->id|/id >>, C<%n> will be replaced by 
L<< $field->name|HTML::FormFu::Element/name >>, C<%t> will be replaced by 
L<< lc( $field->type )|HTML::FormFu::Element/type >>.

Default Value: not defined

This method is a special 'inherited accessor', which means it can be set on 
the form, a block element or a single element. When the value is read, if 
no value is defined it automatically traverses the element's hierarchy of 
parents, through any block elements and up to the form, searching for a 
defined value.

=head2 auto_inflator_class

Arguments: $string

If set, then all form fields will be given an auto-generated class-name 
for each associated inflator.

The following character substitution will be performed: C<%f> will be 
replaced by L<< $form->id|/id >>, C<%n> will be replaced by 
L<< $field->name|HTML::FormFu::Element/name >>, C<%t> will be replaced by 
L<< lc( $field->type )|HTML::FormFu::Element/type >>.

Default Value: not defined

This method is a special 'inherited accessor', which means it can be set on 
the form, a block element or a single element. When the value is read, if 
no value is defined it automatically traverses the element's hierarchy of 
parents, through any block elements and up to the form, searching for a 
defined value.

=head2 auto_validator_class

Arguments: $string

If set, then all form fields will be given an auto-generated class-name 
for each associated validator.

The following character substitution will be performed: C<%f> will be 
replaced by L<< $form->id|/id >>, C<%n> will be replaced by 
L<< $field->name|HTML::FormFu::Element/name >>, C<%t> will be replaced by 
L<< lc( $field->type )|HTML::FormFu::Element/type >>.

Default Value: not defined

This method is a special 'inherited accessor', which means it can be set on 
the form, a block element or a single element. When the value is read, if 
no value is defined it automatically traverses the element's hierarchy of 
parents, through any block elements and up to the form, searching for a 
defined value.

=head2 auto_transformer_class

Arguments: $string

If set, then all form fields will be given an auto-generated class-name 
for each associated validator.

The following character substitution will be performed: C<%f> will be 
replaced by L<< $form->id|/id >>, C<%n> will be replaced by 
L<< $field->name|HTML::FormFu::Element/name >>, C<%t> will be replaced by 
L<< lc( $field->type )|HTML::FormFu::Element/type >>.

Default Value: not defined

This method is a special 'inherited accessor', which means it can be set on 
the form, a block element or a single element. When the value is read, if 
no value is defined it automatically traverses the element's hierarchy of 
parents, through any block elements and up to the form, searching for a 
defined value.

=head1 LOCALIZATION

=head2 languages

Arguments: \@languages

A list of languages which will be passed to the localization object.

Default Value: ['en']

=head2 localize_class

Arguments: $class_name

Classname to be used for the default localization object.

Default Value: 'HTML::FormFu::I18N'

=head2 localize

=head2 loc

Arguments: $key, @arguments

Compatible with the C<maketext> method in L<Locale::Maketext>.

=head1 PROCESSING A FORM

=head2 query

=head2 query_type

=head2 process

=head1 SUBMITTED FORM VALUES AND ERRORS

=head2 submitted

=head2 submitted_and_valid

=head2 params

=head2 param

=head2 valid

=head2 has_errors

=head2 get_errors

=head2 get_error

=head1 MODIFYING A SUBMITTED FORM

=head2 add_valid

=head2 delete_errors

=head1 RENDERING A FORM

=head2 render

=head2 start_form

=head2 end_form

=head2 hidden_fields

=head1 ADVANCED CUSTOMISATION

=head2 filename

Change the template filename used for the form.

Default Value: "form"

=head2 render_class

Set the classname used to create a form render object. If set, the values of 
L</render_class_prefix> and L</render_class_suffix> are ignored.

Default Value: none

=head2 render_class_prefix

Set the prefix used to generate the classname of the form render object and 
all Element render objects.

Default Value: "HTML::FormFu::Render"

=head2 render_class_suffix

Set the suffix used to generate the classname of the form render object.

Default Value: "Form"

=head2 render_class_args

Arguments: \%constructor_arguments

Accepts a hash-ref of arguments passed to the render object constructor for 
the form and all elements.

The default render class (L<HTML::FormFu::Render::Base>) passes these 
arguments to the L<TT|Template> constructor.

The keys C<RELATIVE> and C<RECURSION> are overridden to always be true, as 
these are a basic requirement for the L<Template> engine.

The default value of C<INCLUDE_PATH> is C<root>. This should generally be 
overridden to point to the location of the HTML::FormFu template files on 
your local system.

=head2 render_method

=head1 INTROSPECTION

=head2 get_elements

Arguments: %options

Arguments: \%options

Return Value: \@elements

    my $elements = $form->get_elements;

Returns all top-level (not recursive) elements in the form.

Accepts both C<name> and C<type> arguments to narrow the returned results.

    $form->get_elements({
        name => 'foo',
        type => 'radio',
    });

See L</get_all_elements> for a recursive version.

=head2 get_element

Arguments: %options

Arguments: \%options

Return Value: $element

    my $element = $form->get_element;

Accepts the same arguments as L</get_elements>, but only returns the first 
element found.

=head2 get_all_elements

=head2 get_fields

Arguments: %options

Arguments: \%options

Return Value: \@elements

    my $fields = $form->get_fields;

Returns all form-field type elements in the form (specifically, all elements 
which have a true L<HTML::FormFu::Element/is_field> value.

Accepts both C<name> and C<type> arguments to narrow the returned results.

    $form->get_fields({
        name => 'foo',
        type => 'radio',
    });

=head2 get_field

Arguments: %options

Arguments: \%options

Return Value: $element

    my $field = $form->get_field;

Accepts the same arguments as L</get_fields>, but only returns the first 
form-field found.

=head2 get_deflators

=head2 get_deflator

=head2 get_filters

Arguments: %options

Arguments: \%options

Return Value: \@filters

    my $filters = $form->get_filters;

Returns all filters from all form-fields.

Accepts a C<type> argument to narrow the returned results.

    $form->get_filters({
        type => 'callback',
    });

=head2 get_filter

Arguments: %options

Arguments: \%options

Return Value: $filter

    my $filter = $form->get_filter;

Accepts the same arguments as L</get_filters>, but only returns the first 
filter found.

=head2 get_constraints

Arguments: %options

Arguments: \%options

Return Value: \@constraints

    my $constraints = $form->get_constraints;

Returns all constraints from all form-fields.

Accepts a C<type> argument to narrow the returned results.

    $form->get_constraints({
        type => 'callback',
    });

=head2 get_constraint

Arguments: %options

Arguments: \%options

Return Value: $constraint

    my $constraint = $form->get_constraint;

Accepts the same arguments as L</get_constraints>, but only returns the 
first constraint found.

=head2 get_inflators

=head2 get_inflator

=head2 get_validators

=head2 get_validator

=head2 get_transformers

=head2 get_transformer

=head2 clone

=head1 BEST PRACTICES

It is advisable to keep application-wide (or global) settings in a single 
config file, which should be loaded by each form.

See L</load_config_file>.

=head1 FREQUENTLY ASKED QUESTIONS (FAQ)

=head2 How do I add an onSubmit handler to the form?

    ---
    attributes_xml: { onsubmit: $javascript }

See L<HTML::FormFu/attributes>.

=head2 How do I add an onChange handler to a form field?

    ---
    elements:
      - type: text
        attributes_xml: { onchange: $javascript }

See L<HTML::FormFu::Element/attributes>.

=head2 Element X does not have an accessor for Y!

You can add any arbitrary HTML attributes with 
L<HTML::FormFu::Element/attributes>.

=head2 How can I add a HTML tag which isn't included?

You can use the L<HTML::FormFu::Element::Block> element, and set
the L<tag|HTML::FormFu::Element::Block/tag> to the tag type you want.

    ---
    elements:
      - type: block
        tag: span

=head1 SUPPORT

Project Page:

L<http://code.google.com/p/html-formfu/>

Mailing list:

L<http://lists.rawmode.org/cgi-bin/mailman/listinfo/html-widget>

=head1 BUGS

Please submit bugs / feature requests to either L<rt.perl.org> or 
L<http://code.google.com/p/html-formfu/issues/list>

=head1 SUBVERSION REPOSITORY

The publicly viewable subversion code repository is at 
L<http://html-formfu.googlecode.com/svn/trunk/HTML-FormFu>.

=head1 SEE ALSO

L<HTML::FormFu::Dojo>

L<HTML::FormFu::Imager>

L<Catalyst::Controller::HTML::FormFu>

L<DBIx::Class::FormFu>

=head1 AUTHORS

Carl Franks

Daisuke Maki

Mario Minati

Based on the original source code of L<HTML::Widget>, by Sebastian Riedel, 
C<sri@oook.de>.

=head1 LICENSE

This library is free software, you can redistribute it and/or modify it under
the same terms as Perl itself.

