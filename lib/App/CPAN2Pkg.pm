use 5.012;
use strict;
use warnings;

package App::CPAN2Pkg;
# ABSTRACT: generating native linux packages from cpan

# although it's not strictly needed to load POE::Kernel manually (since
# MooseX::POE will load it anyway), we're doing it here to make sure poe
# will use tk event loop. this can also be done by loading module tk
# before poe, for example if we load app::cpan2pkg::tk::main before
# moosex::poe... but better be safe than sorry, and doing things
# explicitly is always better.
use POE::Kernel { loop => 'Tk' };

use MooseX::Singleton;
use MooseX::Has::Sugar;
use Readonly;

use App::CPAN2Pkg::Controller;
use App::CPAN2Pkg::Tk::Main;
use App::CPAN2Pkg::Utils      qw{ $LINUX_FLAVOUR $WORKER_TYPE };

use POE;

# -- private attributes

# keep track of modules being processed.
has _modules => (
    ro,
    isa     => 'HashRef[App::CPAN2Pkg::Module]',
    traits  => ['Hash'],
    handles => {
        all_modules     => 'keys',
        seen_module     => 'exists',
        register_module => 'set',
        module          => 'get',
    }
);


# -- public methods

=method all_modules

    my @modules = $app->all_modules;

Return the list of all modules that have been / are being processed.

=method seen_module

    my $bool = $app->seen_module( $modname );

Return true if C<$modname> has already been seen. It can be either
finished processing, or still ongoing.

=method register_module

    $app->register_module( $modname, $module );

Store C<$module> as the L<App::CPAN2Pkg::Module> object tracking
C<$modname>.

=method

    my $module = $app->module( $modname );

Return the C<$module> object registered for C<$modname>.

=cut

# those methods above are provided by moose traits for free


=method run

    App::CPAN2Pkg->run( [ @modules ] );

Start the application, with an initial batch of C<@modules> to build.

=cut

sub run {
    my (undef, @modules) = @_;

    # check if the platform is supported
    eval "require $WORKER_TYPE";
    die "Platform $LINUX_FLAVOUR is not supported" if $@ =~ /^Can't locate/;
    die $@ if $@;

    # create the poe sessions
    App::CPAN2Pkg::Controller->new( queue=>\@modules );
    App::CPAN2Pkg::Tk::Main->new;

    # and let's start the fun!
    POE::Kernel->run;
}


#--
# SUBS

#
# if ( not available in cooker )                is_in_dist
# then
#   compute dependencies                        find_prereqs
#   repeat with each dep
#   cpan2dist                                   cpan2dist
#   install local                               install_from_local
#   while ( not available locally )             is_installed
#   do
#       prompt user to fix manually
#   done
#   import                                      import_local_to_dist
#   submit                                              (included above)
#   ack available (manual?)
#
# else
#   urpmi --auto perl(module::to::install)       install_from_dist
# fi

# -- public events

sub available_on_bs {
    # FIXME: start submitting upstream what depends on this
}


sub cpan2dist_status {
    my ($k, $h, $module, $status) = @_[KERNEL, HEAP, ARG0, ARG1];
    # FIXME: what if $status is false

    $k->post($module, 'install_from_local');
}


sub local_install {
    my ($k, $h, $module, $success) = @_[KERNEL, HEAP, ARG0, ARG1];

    if ( not $success ) {
        # module has not been installed locally.
        # FIXME: ask user
        return;
    }

    # module has been installed locally.
    $k->post('ui', 'module_available', $module);

    # module available: nothing depends on it anymore.
    my $name = $module->name;
    $module->is_local(1);
    my @depends = $module->blocking_list;
    $module->blocking_clear;

    # update all modules that were depending on it
    foreach my $m ( @depends ) {
        # remove dependency on module
        my $mobj = $h->_module->{$m};
        $mobj->missing_del($name);
        my @missing = $mobj->missing_list;
        $k->post('ui', 'prereqs', $mobj, @missing);

        if ( scalar @missing == 0 ) {
            # huzzah! no more missing prereqs - let's create a
            # native package for it.
            $k->post($mobj, 'cpan2dist');
        }
    }

    $k->post($module, 'import_upstream');
}


sub local_status {
    my ($k, $h, $module, $is_installed) = @_[KERNEL, HEAP, ARG0, ARG1];

    if ( not $is_installed ) {
        # module is not installed locally, check if
        # it's available upstream.
        $k->post($module, 'is_in_dist');
        return;
    }

    # module is already installed locally.
    $k->post('ui', 'module_available', $module);
    $k->post('ui', 'prereqs', $module);

    # module available: nothing depends on it anymore.
    my $name = $module->name;
    $module->is_local(1);
    $module->is_avail_on_bs(1);
    my @depends = $module->blocking_list;
    $module->blocking_clear;

    # update all modules that were depending on it
    foreach my $m ( @depends ) {
        # remove dependency on module
        my $mobj = $h->_module->{$m};
        $mobj->missing_del($name);
        my @missing = $mobj->missing_list;
        $k->post('ui', 'prereqs', $mobj, @missing);

        if ( scalar @missing == 0 ) {
            # huzzah! no more missing prereqs - let's create a
            # native package for it.
            $k->post($mobj, 'cpan2dist');
        }
    }
}

sub module_spawned {
    my ($k, $h, $module) = @_[KERNEL, HEAP, ARG0];
    my $name = $module->name;
    $h->_module->{$name} = $module;
    $k->post($module, 'is_installed');
}

sub package {
    my ($k, $h, $module) = @_[KERNEL, HEAP, ARG0];
    App::CPAN2Pkg::Worker->spawn($module);
}

sub prereqs {
    my ($k, $h, $module, @prereqs) = @_[KERNEL, HEAP, ARG0..$#_];

    my @missing;
    foreach my $m ( @prereqs ) {
        # check if module is new. in which case, let's treat it.
        if ( ! exists $h->_module->{$m} ) {
            my $mobj = App::CPAN2Pkg::Module->new( name => $m );
            $k->yield('package', $mobj);
            $h->_module->{$m} = $mobj;
        }

        # store missing module.
        push @missing, $m unless $h->_module->{$m}->is_local;
    }

    $k->post('ui', 'prereqs', $module, @missing);
    if ( @missing ) {
        # module misses some prereqs - wait for them.
        my $name = $module->name;
        $module->missing_add($_)               for @missing;
        $h->_module->{$_}->blocking_add($name) for @missing;

    } else {
        # no prereqs, move on
        $k->post($module, 'cpan2dist');
        return;
    }
}

sub upstream_install {
    my ($k, $h, $module, $success) = @_[KERNEL, HEAP, ARG0, ARG1];

    # FIXME: what if $success is a failure?

    # module is already installed locally.
    $k->post('ui', 'module_available', $module);
    $k->post('ui', 'prereqs', $module);

    # module available: nothing depends on it anymore.
    my $name = $module->name;
    $module->is_local(1);
    my @depends = $module->blocking_list;
    $module->blocking_clear;

    # update all modules that were depending on it
    foreach my $m ( @depends ) {
        # remove dependency on module
        my $mobj = $h->_module->{$m};
        $mobj->missing_del($name);
        my @missing = $mobj->missing_list;
        $k->post('ui', 'prereqs', $mobj, @missing);

        if ( scalar @missing == 0 ) {
            # huzzah! no more missing prereqs - let's create a
            # native package for it.
            $k->post($mobj, 'cpan2dist');
        }
    }
}


sub upstream_import {
    my ($k, $h, $module, $success) = @_[KERNEL, HEAP, ARG0, ARG1];
    # FIXME: what if wrong
    my $prereqs = $module->prereqs;
    foreach my $m ( @$prereqs ) {
        my $mobj = $h->_module->{$m};
        next if $mobj->is_avail_on_bs;
        $k->delay( upstream_import => 30, $module, $success );
        return;
    }
    $k->post($module, 'build_upstream');
}


sub upstream_status {
    my ($k, $module, $is_available) = @_[KERNEL, ARG0, ARG1];
    my $event = $is_available ? 'install_from_dist' : 'find_prereqs';
    $k->post($module, $event);
}



no Moose;
__PACKAGE__->meta->make_immutable;

1;
__END__

=head1 SYNOPSIS

    $ cpan2pkg
    $ cpan2pkg Module::Foo Module::Bar ...



=head1 DESCRIPTION

Don't use this module directly, refer to the C<cpan2pkg> script instead.

C<App::CPAN2Pkg> is the main entry point for the C<cpan2pkg> application. It
implements a POE session, responsible to schedule and advance module
packagement.




=head1 PUBLIC EVENTS ACCEPTED

The following events are the module's API.


=head2 available_on_bs()

Sent when module is available on upstream build system.


=head2 cpan2dist_status( $module, $success )

Sent when C<$module> has been C<cpan2dist>-ed, with C<$success> being true
if everything went fine.


=head2 local_install( $module, $success )

Sent when C<$module> has been installed locally, with C<$success> return value.


=head2 local_status( $module, $is_installed )

Sent when C<$module> knows whether it is installed locally (C<$is_installed>
set to true) or not.


=head2 module_spawned( $module )

Sent when C<$module> has been spawned successfully.


=head2 package( $module )

Request the application to package (if needed) a C<$module> (an
C<App::CPAN2Pkg::Module> object).


=head2 prereqs( $module, @prereqs )

Inform main application that C<$module> needs some C<@prereqs> (possibly
empty).


=head2 upstream_import( $module, $success )

Sent when C<$module> package has been imported in upstream repository.


=head2 upstream_install( $module, $success )

Sent after trying to install C<$module> from upstream dist. Result is passed
along with C<$success>.


=head2 upstream_status( $module, $is_available )

Sent when C<$module> knows whether it is available upstream (C<$is_available>
set to true) or not.



=head1 BUGS

Please report any bugs or feature requests to C<app-cpan2pkg at
rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=App-CPAN2Pkg>. I will
be notified, and then you'll automatically be notified of progress on
your bug as I make changes.



=head1 SEE ALSO

Our git repository is located at L<git://repo.or.cz/app-cpan2pkg.git>,
and can be browsed at L<http://repo.or.cz/w/app-cpan2pkg.git>.


You can also look for information on this module at:

=over 4

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/App-CPAN2Pkg>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/App-CPAN2Pkg>

=item * Open bugs

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=App-CPAN2Pkg>

=back


=cut

