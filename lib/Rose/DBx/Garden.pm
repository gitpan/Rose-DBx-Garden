package Rose::DBx::Garden;

use warnings;
use strict;
use base qw( Rose::DB::Object::Loader );
use Carp;
use Data::Dump qw( dump );
use Path::Class;
use File::Slurp;
use File::Basename;

use Rose::Object::MakeMethods::Generic (
    boolean => [
        'find_schemas'  => { default => 1 },
        'force_install' => { default => 0 },
    ],
    'scalar --get_set_init' => 'column_field_map',
    'scalar --get_set_init' => 'column_to_label',
    'scalar --get_set_init' => 'garden_prefix',
    'scalar --get_set_init' => 'perltidy_opts',
    'scalar --get_set_init' => 'base_code',
    'scalar --get_set_init' => 'text_field_size',
);

=head1 NAME

Rose::DBx::Garden - bootstrap Rose::DB::Object and Rose::HTML::Form classes

=head1 VERSION

Version 0.01

B<** DEVELOPMENT RELEASE -- API SUBJECT TO CHANGE **>

=cut

our $VERSION = '0.03';

=head1 SYNOPSIS

 use Rose::DBx::Garden;
    
 my $garden = Rose::DBx::Garden->new(
 
         garden_prefix   => 'MyRoseGarden',    # instead of class_prefix
         perltidy_opts   => '-pbp -nst -nse',  # Perl Best Practices
         db              => My::DB->new, # Rose::DB object
         find_schemas    => 0,           # set true if your db has schemas
         force_install   => 0,           # do not overwrite existing files
         # other Rose::DB::Object::Loader params here
 
 );
                        
 # $garden ISA Rose::DB::Object::Loader
                     
 $garden->plant('path/to/where/i/want/files');

=head1 DESCRIPTION

Rose::DBx::Garden bootstraps Rose::DB::Object and Rose::HTML::Form based projects.
The idea is that you can point the module at a database and end up with work-able
RDBO and Form classes with a single method call.

Rose::DBx::Garden inherits from Rose::DB::Object::Loader, so all the magic there
is also available here.

=head1 METHODS

B<NOTE:> All the init_* methods are intended for when you subclass the Garden
class. You can pass in values to the new() constructor for normal use.
See L<Rose::Object::MakeMethods::Generic>.

=cut

=head2 init_column_field_map

Sets the default RDBO column type to RHTMLO field type mapping.
Should be a hash ref of 'rdbo' => 'rhtmlo' format.

=cut

sub init_column_field_map {
    return {
        'varchar'          => 'text',
        'text'             => 'textarea',
        'character'        => 'text',
        'date'             => 'date',
        'datetime'         => 'datetime',
        'epoch'            => 'datetime',
        'integer'          => 'integer',
        'serial'           => 'hidden',
        'time'             => 'time',
        'timestamp'        => 'datetime',
        'float'            => 'numeric',    # TODO nice to have ::Field::Float
        'numeric'          => 'numeric',
        'decimal'          => 'numeric',
        'double precision' => 'numeric',
        'boolean'          => 'boolean',
    };
}

=head2 init_column_to_label

Returns a CODE ref for filtering a column name to its corresponding
form field label. The CODE ref should expect two arguments:
the Garden object and the column name.

The default is just to return the column name. If you wanted to return,
for example, a prettier version aligned with the naming conventions used
in Rose::DB::Object::ConventionManager, you might do something like:

    my $garden = Rose::DBx::Garden->new(
                    column_to_label => sub {
                           my ($garden_obj, $col_name) = @_;
                           return join(' ', 
                                       map { ucfirst($_) }
                                       split(m/_/, $col_name)
                                  );
                    }
                  );

=cut

sub init_column_to_label {
    sub { return $_[1] }
}

=head2 init_garden_prefix

The default base class name is C<MyRoseGarden>. This value
overrides C<class_prefix> and C<base_class> in the base Loader class.

=cut

sub init_garden_prefix {'MyRoseGarden'}

=head2 init_perltidy_opts

If set, Perl::Tidy will be called to format all generated code. The
value of perltidy_opts should be the same as the command-line options
to perltidy.

The default is 0 (no run through Perl::Tidy).

=cut

sub init_perltidy_opts {0}

=head2 init_text_field_size

Tie the size and maxlength of text input fields to the allowed length
of text columns. Should be set to an integer corresponding to the max
size of a text field. The default is 64.

=cut

sub init_text_field_size {64}

=head2 init_base_code

The return value is inserted into the base RDBO class created.

=cut

sub init_base_code {''}

=head2 plant( I<path> )

I<path> will override module_dir() if set in new().

Returns an array ref of all the class names created.

=head2 make_garden

An alias for plant().

=cut

*make_garden = \&plant;

sub plant {
    my $self = shift;
    my $path = shift or croak "path required";

    #carp "path = $path";

    my $path_obj = dir($path);

    $path_obj->mkpath(1);

    # make sure we can 'require' files we generate
    unshift( @INC, $path );

    # set in loader just in case
    $self->module_dir($path);

    my $garden_prefix = $self->garden_prefix;

    my $base_code = $self->base_code;

    # make the base class unless it already exists
    my $base_template = <<EOF;
package $garden_prefix;
use strict;
use base qw( Rose::DB::Object );

$base_code

1;
EOF

    $self->_make_file( $garden_prefix, $base_template )
        unless ( defined $base_code && $base_code eq '0' );

    # find all schemas if this db supports them
    my %schemas;
    if ( $self->find_schemas ) {
        my %native = ( information_schema => 1, pg_catalog => 1 );
        my $info = $self->db->dbh->table_info( undef, '%', undef, 'TABLE' )
            ->fetchall_arrayref;

        #carp dump $info;

        for my $row (@$info) {
            next if exists $native{ $row->[1] };
            $schemas{ $row->[1] }++;
        }
    }
    else {
        %schemas = ( '' => '' );
    }

    my ( @rdbo_classes, @form_classes );

    my $preamble = $self->module_preamble;

    my $postamble = $self->module_postamble;

    $Rose::DB::Object::Loader::Debug = $ENV{PERL_DEBUG} || 0;

    for my $schema ( keys %schemas ) {

        #carp "working on schema $schema";

        my $schema_class
            = $schema
            ? join( '::', $garden_prefix, ucfirst($schema) )
            : $garden_prefix;

        if ($schema) {
            my $schema_tmpl
                = $self->_schema_template( $garden_prefix, $schema_class,
                $schema );

            $self->_make_file( $schema_class, $schema_tmpl );
            $self->db_schema($schema);
        }

        #carp "schema_class: $schema_class";

        $self->class_prefix($schema_class);
        $self->base_class($schema_class);   # already wrote it, so can require

        my @classes = $self->make_classes;

        #carp dump \@classes;

        for my $class (@classes) {

            #carp "class: $class";

            my $template = my $this_preamble = my $this_postamble = '';

            if ( $class->isa('Rose::DB::Object') ) {

                $template = $class->meta->perl_class_definition( indent => 4 )
                    . "\n";

                if ($preamble) {
                    $this_preamble
                        = ref $preamble eq 'CODE'
                        ? $preamble->( $class->meta )
                        : $preamble;
                }

                if ($postamble) {
                    my $this_postamble
                        = ref $postamble eq 'CODE'
                        ? $postamble->( $class->meta )
                        : $postamble;
                }

                push( @rdbo_classes, $class );
            }
            elsif ( $class->isa('Rose::DB::Object::Manager') ) {
                $template
                    = $class->perl_class_definition( indent => 4 ) . "\n";

                if ($preamble) {
                    $this_preamble
                        = ref $preamble eq 'CODE'
                        ? $preamble->( $class->object_class->meta )
                        : $preamble;
                }

                if ($postamble) {
                    $this_postamble
                        = ref $postamble eq 'CODE'
                        ? $postamble->( $class->object_class->meta )
                        : $postamble;
                }
            }
            else {
                croak "class $class not supported";
            }

            $self->_make_file( $class,
                $this_preamble . $template . $this_postamble );
        }

    }

    # RDBO classes all done. That was the easy part.
    # now create a RHTMLO::Form tree using the same model
    # by default we create a ::Form for each RDBO class,
    # even though in practice we wouldn't
    # use some of them (*_map classes e.g.).

    # first create the base ::Form class.
    my $base_form_class = join( '::', $garden_prefix, 'Form' );
    my $base_form_template = <<EOF;
package $base_form_class;
use strict;
use base qw( Rose::HTML::Form );
1;
EOF

    $self->_make_file( $base_form_class, $base_form_template );

    for my $rdbo_class (@rdbo_classes) {

        # don't make forms for map tables
        if ( $self->convention_manager->is_map_class($rdbo_class) ) {
            print " ... skipping map_class $rdbo_class\n";
            next;
        }

        my $form_class = join( '::', $rdbo_class, 'Form' );
        my $form_template = $self->_form_template( $rdbo_class, $form_class,
            $base_form_class );

        push( @form_classes, $form_class );

        $self->_make_file( $form_class, $form_template );
    }

    return [ @rdbo_classes, @form_classes ];
}

sub _form_template {
    my ( $self, $rdbo_class, $form_class, $base_form_class ) = @_;

    # load the rdbo class and examine its metadata
    # make sure rdbo_class is loaded
    eval "require $rdbo_class";
    croak "can't load $rdbo_class: $@" if $@;

    # create a form template using the column definitions
    # as seed for the form field definitions
    # use the convention manager to assign default field labels

    my $form = <<EOF;
package $form_class;
use strict;
use base qw( $base_form_class );

use Rose::HTMLx::Form::Field::Boolean;
use Rose::HTMLx::Form::Field::Autocomplete;

__PACKAGE__->field_type_classes->{boolean}      = 'Rose::HTMLx::Form::Field::Boolean';
__PACKAGE__->field_type_classes->{autocomplete} = 'Rose::HTMLx::Form::Field::Autocomplete';

sub build_form {
    my \$self = shift;
    
    \$self->add_fields(
    
EOF

    my @fields;
    my $count = 0;
    for my $column ( sort __by_position $rdbo_class->meta->columns ) {
        push( @fields, $self->_column_to_field( $column, ++$count ) );
    }

    $form .= join( "\n", @fields );
    $form .= <<EOF;
    );
    
    return \$self->SUPER::build_form(\@_);
}

1;

EOF

    return $form;
}

# keep columns in same order they appear in db
sub __by_position {
    my $pos1 = $a->ordinal_position;
    my $pos2 = $b->ordinal_position;

    if ( defined $pos1 && defined $pos2 ) {
        return $pos1 <=> $pos2 || lc( $a->name ) cmp lc( $b->name );
    }

    return lc( $a->name ) cmp lc( $b->name );
}

sub _column_to_field {
    my ( $self, $column, $tabindex ) = @_;
    my $col_type    = $column->type;
    my $type        = $self->column_field_map->{$col_type} || 'text';
    my $field_maker = 'garden_' . $type . '_field';
    my $label_maker = $self->column_to_label;
    my $label       = $label_maker->( $self, $column->name );

    unless ( $self->can($field_maker) ) {
        $field_maker = 'garden_default_field';
    }

    return $self->$field_maker( $column, $label, $tabindex );
}

=head2 garden_default_field( I<column>, I<label>, I<tabindex> )

Returns the Perl code text for creating a generic Form field.

=cut

sub garden_default_field {
    my ( $self, $column, $label, $tabindex ) = @_;
    my $col_type = $column->type;
    my $type     = $self->column_field_map->{$col_type} || 'text';
    my $name     = $column->name;
    my $length   = $column->can('length') ? $column->length() : 0;
    $length = 0 unless defined $length;
    my $maxlen = $self->text_field_size;

    if ( $length > $maxlen ) {
        $length = $maxlen;
    }
    return <<EOF;
    $name => {
        id          => '$name',
        type        => '$type',   # $col_type
        label       => '$label',
        tabindex    => $tabindex,
        rank        => $tabindex,
        size        => $length,
        maxlength   => $maxlen,
        },
EOF
}

=head2 garden_boolean_field( I<column>, I<label>, I<tabindex> )

Returns the Perl code text for creating a boolean Form field.

=cut

sub garden_boolean_field {
    my ( $self, $column, $label, $tabindex ) = @_;
    my $col_type = $column->type;
    my $name     = $column->name;

    return <<EOF;
    $name => {
        id          => '$name',
        type        => 'boolean',   # $col_type
        label       => '$label',
        tabindex    => $tabindex,
        rank        => $tabindex,
        },
EOF
}

=head2 garden_text_field( I<column>, I<label>, I<tabindex> )

Returns the Perl code text for creating a text Form field.

=cut

sub garden_text_field {
    my ( $self, $column, $label, $tabindex ) = @_;
    my $col_type = $column->type;
    my $name     = $column->name;
    my $length   = $column->can('length') ? $column->length() : 0;
    $length = 0 unless defined $length;
    my $maxlen = $self->text_field_size;

    if ( $length > $maxlen ) {
        $length = $maxlen;
    }
    return <<EOF;
    $name => {
        id          => '$name',
        type        => 'text',   # $col_type
        label       => '$label',
        tabindex    => $tabindex,
        rank        => $tabindex,
        size        => $length,
        maxlength   => $maxlen,
        },
EOF
}

=head2 garden_textarea_field( I<column>, I<label>, I<tabindex> )

Returns Perl code for textarea field.

=cut

sub garden_textarea_field {
    my ( $self, $column, $label, $tabindex ) = @_;
    my $col_type = $column->type;
    my $name     = $column->name;
    my $length   = $column->can('length') ? $column->length() : 0;
    $length = 0 unless defined $length;
    my $maxlen = $self->text_field_size;

    if ( $length > $maxlen ) {
        $length = $maxlen;
    }
    return <<EOF;
    $name => {
        id          => '$name',
        type        => 'text',   # $col_type
        label       => '$label',
        tabindex    => $tabindex,
        rank        => $tabindex,
        size        => $maxlen . 'x8',
        },
EOF
}

=head2 garden_hidden_field( I<column>, I<label>, I<tabindex> )

Returns the Perl code text for creating a hidden Form field.

=cut

sub garden_hidden_field {
    my ( $self, $column, $label, $tabindex ) = @_;
    my $col_type = $column->type;
    my $name     = $column->name;
    return <<EOF;
    $name => {
        id      => '$name',
        type    => 'hidden',   # $col_type
        label   => '$label',
        rank    => $tabindex,
        },
EOF
}

sub _schema_template {
    my ( $self, $base, $package, $schema ) = @_;

    return <<EOF;
package $package;
use strict;
use base qw( $base );

sub schema { '$schema' }

1;
EOF
}

sub _make_file {
    my ( $self, $class, $buffer ) = @_;
    ( my $file = $class ) =~ s,::,/,g;
    $file .= '.pm';

    my ( $name, $path, $suffix ) = fileparse( $file, qr{\.pm} );

    my $fullpath = dir( $self->module_dir, $path );

    unless ( $self->force_install ) {
        if ( -s $file ) {
            print " ... skipping $class ($file)\n";
            return;
        }
    }

    $fullpath->mkpath(1) if $path;

    if ( $self->perltidy_opts ) {
        require Perl::Tidy;
        my $newbuf;
        Perl::Tidy::perltidy(
            source      => \$buffer,
            destination => \$newbuf,
            argv        => $self->perltidy_opts
        );
        $buffer = $newbuf;
    }

    write_file( file( $self->module_dir, $file )->stringify, $buffer )
        or die "$!\n";

    print "$class written to $file\n";
}

=head1 AUTHORS

Peter Karman, C<< <karman at cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to
C<bug-rose-dbx-garden at rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Rose-DBx-Garden>.
I will be notified, and then you'll automatically be notified of progress on
your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Rose::DBx::Garden

You can also look for information at:

=over 4

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Rose-DBx-Garden>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Rose-DBx-Garden>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Rose-DBx-Garden>

=item * Search CPAN

L<http://search.cpan.org/dist/Rose-DBx-Garden>

=back

=head1 ACKNOWLEDGEMENTS

Thanks to Adam Prime, C<< adam.prime at utoronto.ca >>
for patches and feedback on the design.

The Minnesota Supercomputing Institute C<< http://www.msi.umn.edu/ >>
sponsored the development of this software.

=head1 COPYRIGHT & LICENSE

Copyright 2007 by the Regents of the University of Minnesota.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

1;    # End of Rose::DBx::Garden
