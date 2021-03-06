!! ----------------------------------------------------------------------------------------------------------------------------- !!
!>
!! Snapshot/waveform output
!!
!! @copyright
!!   Copyright 2013-2016 Takuto Maeda. All rights reserved. This project is released under the MIT license.
!<
!! ----
#include "m_debug.h"
module m_output

  !! -- Dependency
  use m_std
  use m_debug
  use m_global
  use m_pwatch
  use m_fdtool
  use m_daytim
  use m_wsac
  use m_readini
  use m_geomap
#ifdef _NETCDF
  use netcdf
#endif

  !! -- Declarations
  implicit none
  private
  save

  public :: output__setup
  public :: output__write_snap
  public :: output__store_wav
  public :: output__export_wav
  public :: output__checkpoint
  public :: output__restart
  public :: output__closefiles

  !! -- Internal Parameters
  character(8), parameter :: BINARY_TYPE= "STREAMIO"
  !! character(8), parameter :: BINARY_TYPE= "UNFORMAT" ! for architectures that does not support fortran2003
  character(8), parameter :: CODE_TYPE  = "SWPC_SH "   !!< FIXED parameter for file header
  integer,      parameter :: HEADER_VERSION = 6
  !! header_version history
  !! 110311 : original
  !! 2      : added binary_type (character(8))
  !! 3      : added Lz and zeta for curvilinear
  !! 4      : added w for curvilinear
  !! 5      : added coordinate rotation angle phi
  !! 6      : seism -> swpc

  !! -- Internal variables
  type snp
     logical :: sw
     integer :: io
     integer :: ionode
     integer :: nsnp
     character(2) :: snaptype ! snapshot type
     character(2) :: coordinate = 'xz'
     integer :: nmed = 3
     integer :: na1, na2 ! absorbing layer

     !! variables for netcdf mode
     integer :: did_x1, did_x2, did_t ! dimension id for independent vars
     integer :: vid_x1, vid_x2, vid_t ! variable  id for independent vars
     integer :: varid(10)           ! variable  id for dependent vars
     integer :: medid(10)            ! medium array id
     real    :: vmax(10), vmin(10)  ! max/min of dependent vars
     character(10) :: vname(10)
     character(10) :: vunit(10)
  end type snp

  type(snp) :: xz_v, xz_u
  logical   :: sw_wav, sw_wav_v, sw_wav_u

  !! switch
  integer   :: ntdec_s, ntdec_w                                !< time step decimation factor: Snap and Waves
  integer   :: idec, kdec                                !< spatial decimation factor: x, y, z
  character(2):: st_format                                       !< station file format
  character(3) :: wav_format
  character(256) :: fn_stloc

  integer :: nxs, nzs !< snapshot grid size
  real(SP), allocatable :: xsnp(:), zsnp(:)

  !! station
  integer :: nst
  real(SP), allocatable :: xst(:), zst(:)
  integer,  allocatable :: ist(:), kst(:)
  real(SP), allocatable :: stlo(:), stla(:)
  character(8), allocatable :: stnm(:)

  !! waveform
  integer :: ntw ! number of wave samples
  real(SP), allocatable :: vyst(:,:), uyst(:,:)
  type(sac__hdr), allocatable :: sh(:,:)
  real(SP), allocatable :: uy(:)

  !! I/O area in the node
  integer :: is0, is1, ks0, ks1

  !! derivative coefficient
  real(SP) :: r20x, r20z

  character(6) :: snp_format ! native or netcdf

  real(SP), allocatable :: buf_u(:,:) !! displacement buffer
contains

  !! --------------------------------------------------------------------------------------------------------------------------- !!
  !>
  !! Setup
  !!
  !! @see
  !! #2012-41 #2013-00440
  !<
  !! ----
  subroutine output__setup( io_prm )

    integer, intent(in) :: io_prm
    integer :: i, k, ii, kk
    !! ----

    call pwatch__on( "output__setup" )

    !!
    !! read parameter
    !!

    call readini( io_prm, 'xz_v%sw',  xz_v%sw,  .false. )
    call readini( io_prm, 'xz_u%sw',  xz_u%sw,  .false. )
    call readini( io_prm, 'idec',      idec,      1       )
    call readini( io_prm, 'kdec',      kdec,      1       )
    call readini( io_prm, 'ntdec_s',   ntdec_s,   10      )
    call readini( io_prm, 'ntdec_w',   ntdec_w,   10      )
    call readini( io_prm, 'st_format', st_format, 'xy'    )
    call readini( io_prm, 'fn_stloc',  fn_stloc,  ''      )
    call readini( io_prm, 'sw_wav_v',  sw_wav_v,  .false. )
    call readini( io_prm, 'sw_wav_u',  sw_wav_u,  .false. )

    call readini( io_prm, 'snp_format', snp_format, 'native' )
    call readini( io_prm, 'wav_format', wav_format, 'sac' )

    sw_wav = ( sw_wav_v .or. sw_wav_u )

    !!!!
    !!!! snapshot
    !!!!

    !!
    !! snapshot size #2013-0440
    !!
    nxs = ( nx + (idec/2) ) / idec
    nzs = ( nz + (kdec/2) ) / kdec

    !!
    !! coordinate
    !!
    allocate( xsnp(nxs), zsnp(nzs) )
    do i=1, nxs
       ii = i*idec - (idec/2)
       xsnp(i) = i2x( ii, xbeg, real(dx) )
    end do
    do k=1, nzs
       kk = k*kdec - (kdec/2)
       zsnp(k) = k2z( kk, zbeg, real(dz) )
    end do

    !! snapshot region covered by the MPI node
    is0 = ceiling( ( ibeg + idec/2) / real(idec) )
    is1 = floor  ( ( iend + idec/2) / real(idec) )
    ks0 = ceiling( ( kbeg + kdec/2) / real(kdec) )
    ks1 = floor  ( ( kend + kdec/2) / real(kdec) )


    !! number of snapshots per cycle
    xz_v  % nsnp = 1
    xz_u  % nsnp = 1

    xz_v  % snaptype  = 'vy'
    xz_u  % snaptype  = 'uy'

    xz_v  % vname(1) = 'Vy'
    xz_v  % vunit(1) = 'm/s'
    xz_u  % vname(1) = 'Uy'
    xz_u  % vunit(1) = 'm'

    !!
    !! output node definition: cyclic
    !!
    xz_v%ionode = mod( 1, nproc_x )
    xz_u%ionode = mod( 2, nproc_x )


    !!
    !! open
    !!

    !!
    !! output settings
    !!
    if( snp_format == 'native' ) then
       if( xz_v%sw ) call newfile_xz(   trim(odir) // '/' // trim(title) //'.xz.v.snp', xz_v )
       if( xz_u%sw ) call newfile_xz(   trim(odir) // '/' // trim(title) //'.xz.u.snp', xz_u )
    else
       if( xz_v%sw ) call newfile_xz_nc(   trim(odir) // '/' // trim(title) //'.xz.v.nc', xz_v )
       if( xz_u%sw ) call newfile_xz_nc(   trim(odir) // '/' // trim(title) //'.xz.u.nc', xz_u )
    end if

    !! for taking derivatives
    r20x = 1 / dx
    r20z = 1 / dz


    allocate(buf_u(nxs,nzs))
    buf_u(:,:) = 0.0

    !!!!
    !!!! waveform
    !!!!

    if( sw_wav ) then

       ntw = floor( real(nt-1)/real(ntdec_w) + 1.0 )

       call read_stinfo()

    end if


    call pwatch__off( "output__setup" )

  end subroutine output__setup
  !! --------------------------------------------------------------------------------------------------------------------------- !!


  !! --------------------------------------------------------------------------------------------------------------------------- !!
  !>
  !<
  !! --
  subroutine output__export_wav()
    integer :: i
    character(256) :: fn1, fn2
    character(6) :: cid
    call pwatch__on("output__export_wav")

    if( nst>0 ) call system__call('mkdir '//trim(odir)//'/wav > /dev/null 2>&1' )

    if( wav_format == 'sac' ) then
      do i=1, nst
        
        if( sw_wav_v ) then
          fn1 = trim(odir) // '/wav/' // trim(title) // '.' // trim(stnm(i)) // '.Vy.sac'
          call sac__write( fn1, sh(1,i), vyst(:,i), .true. )
          
        end if
        
        if( sw_wav_u ) then
          fn2 = trim(odir) // '/wav/' // trim(title) // '.' // trim(stnm(i)) // '.Uy.sac'
          call sac__write( fn2, sh(2,i), uyst(:,i), .true. )
        end if
        
      end do
    else if (wav_format == 'csf' ) then

      write(cid,'(I6.6)') myid

      if( sw_wav_v ) then
        fn1 = trim(odir) // '/wav/' // trim(title) // '.' // trim(cid) // '.Vy.sac'
        call csf__write( fn1, nst, sh(1,1)%npts, sh(1,:), vyst(:,:), .true. )
        
      end if
      
      if( sw_wav_u ) then
        fn2 = trim(odir) // '/wav/' // trim(title) // '.' // trim(cid) // '.Uy.sac'
        call csf__write( fn2, nst, sh(2,1)%npts, sh(2,:), uyst(:,:), .true. )
      end if

    end if
    
      
    call pwatch__off("output__export_wav")


  end subroutine output__export_wav
  !! --------------------------------------------------------------------------------------------------------------------------- !!


  !! --------------------------------------------------------------------------------------------------------------------------- !!
  !>
  !! Set-up waveform file. Create, header output.
  !<
  !! --
  subroutine read_stinfo( )

    integer                   :: io_stlst
    real(SP), allocatable     :: xst_g(:), zst_g(:), stlo_g(:), stla_g(:)
    integer, allocatable      :: ist_g(:), kst_g(:), stid(:)
    character(3), allocatable :: zsw_g(:)
    character(8), allocatable :: stnm_g(:)
    character(256)            :: abuf
    integer                   :: ierr
    integer :: nst_g
    integer :: i, ii, j
    real(SP) :: rdum
    real(SP) :: mw
    !! ----

    !!!!
    !!!! Read station location file
    !!!!

    call std__getio(io_stlst)
    open(io_stlst, file=trim(fn_stloc), action='read', iostat = ierr, status='old' )

    if( ierr /= 0 ) then

       nst_g = 0          ! not exist
       sw_wav = .false.
       if( myid == 0 ) then
          write(STDERR,'(A)') "[INFO] output--read_stinfo: Station file does not exist. WAV file will not be created"
       end if
       return

    else
       call std__countline( io_stlst, nst_g, "#" )
    end if

    !! allocate temp memory
    allocate( xst_g(nst_g), zst_g(nst_g), stnm_g(nst_g), zsw_g(nst_g), stlo_g(nst_g), stla_g(nst_g) )
    allocate( ist_g(nst_g), kst_g(nst_g), stid(nst_g) )


    !!
    !! First, store all station location into memory, and select station inside the MPI node
    !!
    nst = 0

    !! once recet total number of station
    !! count-up stations only inside the computation domain
    nst_g = 0
    i = 0

    !! moment magnitude for header part
    mw = moment_magnitude( m0 )

    do
       read(io_stlst,'(A256)', iostat=ierr) abuf
       if( ierr /= 0)  exit
       if( adjustl(abuf(1:1)) == "#" ) cycle ! neglect comment line
       if( trim(adjustl(abuf)) == "" ) cycle ! neglect blank line

       i = i + 1

       select case ( st_format )

         case( 'xy' )

            read(abuf,*) xst_g(i), rdum, zst_g(i), stnm_g(i), zsw_g(i)
            call geomap__c2g( xst_g(i), 0.0, clon, clat, phi, stlo_g(i), stla_g(i) )


         case( 'll' )

            read(abuf,*) stlo_g(i), stla_g(i), zst_g(i), stnm_g(i), zsw_g(i)
            call geomap__g2c( stlo_g(i), stla_g(i), clon, clat, phi, xst_g(i), rdum )

         case default

            write(STDERR,'(A)') "ERROR [output__stinfo]: unrecognized station format."
            stop

       end select


       ! digitize
       ist_g(i) = x2i ( xst_g(i), xbeg, real(dx) )
       kst_g(i) = z2k ( zst_g(i), zbeg, real(dz) )


       !! check if the station is in the computational domain
       if(  i2x( 1, xbeg, real(dx) ) < xst_g(i) .and. xst_g(i) < i2x( nx, xbeg, real(dx) ) .and. &
                    kbeg             < kst_g(i) .and. kst_g(i) <          kend                 )  then


          !! memorize station location
          nst_g = nst_g + 1

          !! MPI region check: memorize station number
          if( ibeg <= ist_g(i) .and. ist_g(i) <= iend ) then

             nst = nst + 1
             stid(nst) = i

           end if

       else
          if( myid == 0 )  write(STDERR,'(A)') "WARNING [output__setup]: station " // trim( stnm_g(i) ) // " is out of the region"
       end if
    end do

    close( io_stlst )

    if( nst_g == 0 ) then
       sw_wav = .false.
       if( myid == 0 ) then
          write(STDERR,*) "[INFO] output--read_stinfo: No station is detected. WAV file will not be created"
       end if
       return
    end if


    if( nst == 0 ) return


    allocate( xst(nst), zst(nst), ist(nst), kst(nst), stnm(nst), stlo(nst), stla(nst) )


    do i = 1, nst

       ii = stid(i)

       xst(i) = xst_g(ii)
       zst(i) = zst_g(ii)
       ist(i) = ist_g(ii)
       ist(i) = ist_g(ii)
       stnm(i) = stnm_g(ii)
       stlo(i) = stlo_g(ii)
       stla(i) = stla_g(ii)

       !! station depth setting
       !! this is done only for MPI-node because of the definition of kfs and kob
       select case ( zsw_g(ii) )
         case( 'dep' );    kst(i) = kst_g(ii)
         case( 'fsb' );    kst(i) = kfs( ist(i) ) + 1   !! free surface: one-grid below for avoiding vacuum
         case( 'obb' );    kst(i) = kob( ist(i) ) + 1   !! ocean column: below seafloor
         case( 'oba' );    kst(i) = kob( ist(i) ) - 1   !! ocean column: above seafloor
         case( 'bd0' );    kst(i) = z2k( bddep(ist(i),0), zbeg, real(dz) ) !! Boundary interface
         case( 'bd1' );    kst(i) = z2k( bddep(ist(i),1), zbeg, real(dz) ) !! Boundary interface
         case( 'bd2' );    kst(i) = z2k( bddep(ist(i),2), zbeg, real(dz) ) !! Boundary interface
         case( 'bd3' );    kst(i) = z2k( bddep(ist(i),3), zbeg, real(dz) ) !! Boundary interface
         case( 'bd4' );    kst(i) = z2k( bddep(ist(i),4), zbeg, real(dz) ) !! Boundary interface
         case( 'bd5' );    kst(i) = z2k( bddep(ist(i),5), zbeg, real(dz) ) !! Boundary interface
         case( 'bd6' );    kst(i) = z2k( bddep(ist(i),6), zbeg, real(dz) ) !! Boundary interface
         case( 'bd7' );    kst(i) = z2k( bddep(ist(i),7), zbeg, real(dz) ) !! Boundary interface
         case( 'bd8' );    kst(i) = z2k( bddep(ist(i),8), zbeg, real(dz) ) !! Boundary interface
         case( 'bd9' );    kst(i) = z2k( bddep(ist(i),9), zbeg, real(dz) ) !! Boundary interface
         case default; kst(i) = kst_g(ii)
       end select

       !! depth check
       if( kst(i) > kend ) then
          write(STDERR,*) 'WARNING[output__setup]: station depth exceeds kend at station ' // trim(stnm(i))
          kst(i) = kend - 1
       end if
       if( kst(i) < kbeg ) then
          write(STDERR,*) 'WARNING[output__setup]: station depth exceeds kbeg at station ' // trim(stnm(i))
          kst(i) = kbeg + 1
       end if


    end do

    allocate( vyst(ntw,nst), uyst(ntw,nst) )
    vyst(:,:) = 0.0
    uyst(:,:) = 0.0

    !!
    !! set-up sac header
    !!
    allocate( sh(2,nst) )
    do i=1, nst

       !! first initialize header type
       do j=1, 2
          call sac__init(sh(j,i))
       end do

       !! common header
       sh(:,i)%evlo    = evlo
       sh(:,i)%evla    = evla
       sh(:,i)%evdp    = evdp*1000
       sh(:,i)%tim     = exedate
       sh(:,i)%b       = tbeg
       sh(:,i)%delta   = ntdec_w * dt
       sh(:,i)%npts    = ntw
       sh(:,i)%mag     = mw
       if( bf_mode ) then
          sh(:,i)%user0   = fx0
          sh(:,i)%user1   = fy0
          sh(:,i)%user2   = fz0
       else
          sh(:,i)%user0   = mxx0
          sh(:,i)%user1   = myy0
          sh(:,i)%user2   = mzz0
          sh(:,i)%user3   = myz0
          sh(:,i)%user4   = mxz0
          sh(:,i)%user5   = mxy0
       end if
       sh(:,i)%user6   = clon !< coordinate
       sh(:,i)%user7   = clat !< coordinate
       sh(:,i)%user8   = phi
       sh(:,i)%o       = otim

       !! exedate -> time
       do j=1, 2
          call daytim__localtime( sh(j,i)%tim, &
                                  sh(j,i)%nzyear, sh(j,i)%nzmonth, sh(j,i)%nzday, sh(j,i)%nzhour, sh(j,i)%nzmin, sh(j,i)%nzsec )
          call daytim__ymd2jul  ( sh(j,i)%nzyear, sh(j,i)%nzmonth, sh(j,i)%nzday, sh(j,i)%nzjday )
       end do

       !! station dependent
       sh(:,i)%kevnm = trim(adjustl( title(1:16) ))
       sh(:,i)%kstnm = trim(stnm(i))
       sh(:,i)%stlo  = stlo(i)
       sh(:,i)%stla  = stla(i)
       sh(:,i)%stdp  = zst(i)*1000 ! in meter unit


       !! component dependent
       sh(1,i)%kcmpnm = "Vy"
       sh(2,i)%kcmpnm = "Uy"

       sh(1,i)%cmpinc = 90.0;  sh(1,i)%cmpaz  = 90.0 + phi
       sh(2,i)%cmpinc = 90.0;  sh(2,i)%cmpaz  = 90.0 + phi

       sh(1,i)%idep = 7 ! velocity [nm/s]
       sh(2,i)%idep = 6 ! displacement [nm]

    end do


  end subroutine read_stinfo
  !! --------------------------------------------------------------------------------------------------------------------------- !!

  !! --------------------------------------------------------------------------------------------------------------------------- !!
  !>
  !! Open new file and write header information, and medium parameters for XY-cross section
  !<
  !! ----
  subroutine newfile_xz ( fname, hdr )

    character(*), intent(in)    :: fname
    type(snp),    intent(inout) :: hdr
    !! ----

    integer :: i, k, kk, ii
    real :: buf(nxs, nzs,3)

    !! --

    hdr % na1 = na / idec
    hdr % na2 = na / kdec
    hdr % coordinate = 'xz'


    if( myid == hdr%ionode ) then

       call std__getio( hdr%io, is_big=.true. )
#ifdef _ES
       open( hdr%io, file=trim(fname), action='write', form='unformatted', status='replace' )
#else
       open( hdr%io, file=trim(fname), access='stream', action='write', form='unformatted', status='replace' )
#endif
       call write_snp_header( hdr, nxs, nzs, xsnp(1:nxs), zsnp(1:nzs) )

    end if

    buf = 0.0
    do i = is0, is1
       do k = ks0, ks1

          ii = i * idec - idec/2
          kk = k * kdec - kdec/2

          buf(i,k,1) = rho( kk, ii )
          buf(i,k,2) = lam( kk, ii )
          buf(i,k,3) = mu ( kk, ii )
       end do

    end do

    call write_reduce_array2d_r( nxs, nzs, hdr%ionode, hdr%io, buf(:,:,1) )
    call write_reduce_array2d_r( nxs, nzs, hdr%ionode, hdr%io, buf(:,:,2) )
    call write_reduce_array2d_r( nxs, nzs, hdr%ionode, hdr%io, buf(:,:,3) )

  end subroutine newfile_xz
  !! --------------------------------------------------------------------------------------------------------------------------- !!

  !! --------------------------------------------------------------------------------------------------------------------------- !!
  !>
  !! write snapshot header in fixed format
  !<
  !! --------------------------------------------------------------------------------------------------------------------------- !!
  subroutine write_snp_header( hdr, ns1, ns2, xs1, xs2 )

    type(snp),    intent(in) :: hdr
    integer,      intent(in) :: ns1, ns2
    real(SP),     intent(in) :: xs1(ns1), xs2(ns2) ! first and second axis
    real(SP) :: dum
    !! ----

    write( hdr%io ) BINARY_TYPE
    write( hdr%io ) CODE_TYPE
    write( hdr%io ) HEADER_VERSION
    write( hdr%io ) title
    write( hdr%io ) exedate

    !! space grid size
    write( hdr%io ) hdr%coordinate                ! coordinate
    write( hdr%io ) hdr%snaptype                  ! data type
    write( hdr%io ) ns1
    write( hdr%io ) ns2                       ! data size
    write( hdr%io ) xs1(1)
    write( hdr%io ) xs2(1)
    write( hdr%io ) xs1(2) - xs1(1)
    write( hdr%io ) xs2(2) - xs2(1)

    !! time
    write( hdr%io ) dt * ntdec_s                   ! dt

    ! absorb layer
    write( hdr%io ) hdr%na1
    write( hdr%io ) hdr%na2

    !! number of arrays
    write( hdr%io ) hdr%nmed
    write( hdr%io ) hdr%nsnp

    !! coordinate
    dum = -12345.0
    write( hdr%io ) clon
    write( hdr%io ) clat
    write( hdr%io ) phi

    write( hdr%io ) dum !< dummy
    write( hdr%io ) dum !< dummy
    write( hdr%io ) dum !< dummy

  end subroutine write_snp_header
  !! --------------------------------------------------------------------------------------------------------------------------- !!

  !! --------------------------------------------------------------------------------------------------------------------------- !!
  !>
  !! write netcdf header
  !<
  !! ---
  subroutine write_nc_header( hdr, ns1, ns2, xs1, xs2 )

    type(snp), intent(inout) :: hdr
    integer, intent(in) :: ns1, ns2
    real(SP), intent(in) :: xs1(ns1), xs2(ns2)
    integer :: i
    !! --

    call nc_chk( nf90_def_dim( hdr%io, 'x', nxs, hdr%did_x1 ) )
    call nc_chk( nf90_def_dim( hdr%io, 'z', nzs, hdr%did_x2 ) )
    call nc_chk( nf90_def_dim( hdr%io, 't', NF90_UNLIMITED, hdr%did_t ) )
    call nc_chk( nf90_def_var( hdr%io, 'x', NF90_REAL, hdr%did_x1, hdr%vid_x1 ) )
    call nc_chk( nf90_def_var( hdr%io, 'z', NF90_REAL, hdr%did_x2, hdr%vid_x2 ) )
    call nc_chk( nf90_def_var( hdr%io, 't', NF90_REAL, hdr%did_t, hdr%vid_t ) )

    !! medium
    call nc_chk( nf90_def_var( hdr%io, 'rho',    NF90_REAL, (/hdr%did_x1, hdr%did_x2/), hdr%medid(1) ) )
    call nc_chk( nf90_def_var( hdr%io, 'lambda', NF90_REAL, (/hdr%did_x1, hdr%did_x2/), hdr%medid(2) ) )
    call nc_chk( nf90_def_var( hdr%io, 'mu',     NF90_REAL, (/hdr%did_x1, hdr%did_x2/), hdr%medid(3) ) )

    !! variables
    do i=1, hdr%nsnp
       call nc_chk( nf90_def_var( hdr%io, trim(hdr%vname(i)), NF90_REAL, (/hdr%did_x1, hdr%did_x2, hdr%did_t/), hdr%varid(i) ) )
       call nc_chk( nf90_put_att( hdr%io, hdr%varid(i), 'long_name', trim(hdr%vname(i)) ) )
       call nc_chk( nf90_put_att( hdr%io, hdr%varid(i), 'units', trim(hdr%vunit(i)) ) )
    end do

    !! global attribute
    call nc_chk( nf90_put_att( hdr%io, NF90_GLOBAL, 'generated_by',   'SWPC' ) )
    call nc_chk( nf90_put_att( hdr%io, NF90_GLOBAL, 'title',          trim(title) ) )
    call nc_chk( nf90_put_att( hdr%io, NF90_GLOBAL, 'exedate',        exedate     ) )
    call nc_chk( nf90_put_att( hdr%io, NF90_GLOBAL, 'hdrver',         HEADER_VERSION ) )
    call nc_chk( nf90_put_att( hdr%io, NF90_GLOBAL, 'codetype',       CODE_TYPE ) )
    call nc_chk( nf90_put_att( hdr%io, NF90_GLOBAL, 'ns1',            ns1 ) )
    call nc_chk( nf90_put_att( hdr%io, NF90_GLOBAL, 'ns2',            ns2 ) )
    call nc_chk( nf90_put_att( hdr%io, NF90_GLOBAL, 'beg1',           xs1(1) ) )
    call nc_chk( nf90_put_att( hdr%io, NF90_GLOBAL, 'beg2',           xs2(1) ) )
    call nc_chk( nf90_put_att( hdr%io, NF90_GLOBAL, 'na1',            hdr%na1 ) )
    call nc_chk( nf90_put_att( hdr%io, NF90_GLOBAL, 'na2',            hdr%na2 ) )
    call nc_chk( nf90_put_att( hdr%io, NF90_GLOBAL, 'ds1',            idec * dx ) )
    call nc_chk( nf90_put_att( hdr%io, NF90_GLOBAL, 'ds2',            kdec * dz ) )
    call nc_chk( nf90_put_att( hdr%io, NF90_GLOBAL, 'nmed',           hdr%nmed ) )
    call nc_chk( nf90_put_att( hdr%io, NF90_GLOBAL, 'nsnp',           hdr%nsnp ) )
    call nc_chk( nf90_put_att( hdr%io, NF90_GLOBAL, 'coordinate',     hdr%coordinate ) )
    call nc_chk( nf90_put_att( hdr%io, NF90_GLOBAL, 'datatype',       hdr%snaptype ) )
    call nc_chk( nf90_put_att( hdr%io, NF90_GLOBAL, 'dt',             dt * ntdec_s ) )

    !! variable attributes
    call nc_chk( nf90_put_att( hdr%io, hdr%vid_x1, 'long_name', 'x' ) )
    call nc_chk( nf90_put_att( hdr%io, hdr%vid_x2, 'long_name', 'z' ) )
    call nc_chk( nf90_put_att( hdr%io, hdr%vid_t, 'long_name', 't' ) )
    call nc_chk( nf90_put_att( hdr%io, hdr%vid_x1, 'units', 'km' ) )
    call nc_chk( nf90_put_att( hdr%io, hdr%vid_x2, 'units', 'km' ) )
    call nc_chk( nf90_put_att( hdr%io, hdr%vid_t, 'units', 's' ) )

    call nc_chk( nf90_put_att( hdr%io, hdr%medid(1), 'long_name', 'rho'    ) )
    call nc_chk( nf90_put_att( hdr%io, hdr%medid(2), 'long_name', 'lambda' ) )
    call nc_chk( nf90_put_att( hdr%io, hdr%medid(3), 'long_name', 'mu'     ) )
    call nc_chk( nf90_put_att( hdr%io, hdr%medid(1), 'units', '10^3 kg/cm^3'    ) )
    call nc_chk( nf90_put_att( hdr%io, hdr%medid(2), 'units', '10^9 Pa' ) )
    call nc_chk( nf90_put_att( hdr%io, hdr%medid(3), 'units', '10^9 Pa'     ) )

    call nc_chk( nf90_put_att( hdr%io, hdr%vid_x1, 'actual_range', (/ xs1(1), xs1(ns1) /) ) )
    call nc_chk( nf90_put_att( hdr%io, hdr%vid_x2, 'actual_range', (/ xs2(1), xs2(ns2) /) ) )

    call nc_chk( nf90_put_att( hdr%io, NF90_GLOBAL, 'clon', clon ) )
    call nc_chk( nf90_put_att( hdr%io, NF90_GLOBAL, 'clat', clat ) )
    call nc_chk( nf90_put_att( hdr%io, NF90_GLOBAL, 'phi',  phi  ) )

  end subroutine write_nc_header
  !! --------------------------------------------------------------------------------------------------------------------------- !!

  !! --------------------------------------------------------------------------------------------------------------------------- !!
  subroutine newfile_xz_nc ( fname, hdr )
    character(*), intent(in)    :: fname
    type(snp),    intent(inout) :: hdr
    !!
    real, allocatable :: sbuf(:), rbuf1(:), rbuf2(:), rbuf3(:), buf(:,:,:)
    integer :: i, k, ierr, ii, kk
    !! ---

#ifdef _NETCDF

    if( myid == hdr%ionode ) then

       !! initialize
       hdr%vmax = 0.0
       hdr%vmin = 0.0
       hdr % na1 = na / idec
       hdr % na2 = na / kdec

       call nc_chk( nf90_create( trim(fname), NF90_CLOBBER, hdr%io ) )
       call write_nc_header( hdr, nxs, nzs, xsnp, zsnp )
    end if

    allocate( buf(nxs,nzs,3) )
    buf = 0.0
    do i = is0, is1
       do k = ks0, ks1

          ii = i * idec - idec/2
          kk = k * kdec - kdec/2

          buf(i,k,1) = rho( kk, ii )
          buf(i,k,2) = lam( kk, ii )
          buf(i,k,3) = mu ( kk, ii )

       end do
    end do

    !! medium
    allocate( sbuf(nxs*nzs), rbuf1(nxs*nzs), rbuf2(nxs*nzs), rbuf3(nxs*nzs) )
    sbuf = reshape( buf(:,:,1), shape(sbuf) )
    call mpi_reduce( sbuf, rbuf1, nxs*nzs, MPI_REAL, MPI_SUM, hdr%ionode, mpi_comm_world, ierr )
    sbuf = reshape( buf(:,:,2), shape(sbuf) )
    call mpi_reduce( sbuf, rbuf2, nxs*nzs, MPI_REAL, MPI_SUM, hdr%ionode, mpi_comm_world, ierr )
    sbuf = reshape( buf(:,:,3), shape(sbuf) )
    call mpi_reduce( sbuf, rbuf3, nxs*nzs, MPI_REAL, MPI_SUM, hdr%ionode, mpi_comm_world, ierr )

    if( myid == hdr%ionode ) then

       call nc_chk( nf90_put_att( hdr%io, hdr%medid(1), 'actual_range', (/minval(rbuf1), maxval(rbuf1)/) ) )
       call nc_chk( nf90_put_att( hdr%io, hdr%medid(2), 'actual_range', (/minval(rbuf2), maxval(rbuf2)/) ) )
       call nc_chk( nf90_put_att( hdr%io, hdr%medid(3), 'actual_range', (/minval(rbuf3), maxval(rbuf3)/) ) )

       call nc_chk( nf90_enddef( hdr%io ) )

       call nc_chk( nf90_put_var( hdr%io, hdr%vid_x1, xsnp ) )
       call nc_chk( nf90_put_var( hdr%io, hdr%vid_x2, zsnp ) )
       call nc_chk( nf90_put_var( hdr%io, hdr%medid(1), reshape(rbuf1,shape(buf(:,:,1)) ) ) )
       call nc_chk( nf90_put_var( hdr%io, hdr%medid(2), reshape(rbuf2,shape(buf(:,:,1)) ) ) )
       call nc_chk( nf90_put_var( hdr%io, hdr%medid(3), reshape(rbuf3,shape(buf(:,:,1)) ) ) )

    end if

    deallocate( sbuf, rbuf1, rbuf2, rbuf3, buf )

#endif
  end subroutine newfile_xz_nc
  !! --------------------------------------------------------------------------------------------------------------------------- !!


  !! --------------------------------------------------------------------------------------------------------------------------- !!
  !>
  !! write 2d array with MPI
  !<
  !! --------------------------------------------------------------------------------------------------------------------------- !!
  subroutine write_reduce_array2d_r( nx1, nx2, ionode, io, array )

    integer,  intent(in) :: nx1, nx2
    integer,  intent(in) :: ionode
    integer,  intent(in) :: io
    real(SP), intent(in) :: array(nx1,nx2)

    real(SP) :: sbuf(nx1*nx2)
    real(SP) :: rbuf(nx1*nx2)
    integer  :: ierr

    !! prepare send buffer
    sbuf = reshape( array, shape(sbuf) )

    !! gather to io_node
    call mpi_reduce( sbuf, rbuf, nx1*nx2, MPI_REAL, MPI_SUM, ionode, mpi_comm_world, ierr )

    !! write
    if( myid == ionode ) write(io) rbuf

  end subroutine write_reduce_array2d_r
  !! --------------------------------------------------------------------------------------------------------------------------- !!

  !! --------------------------------------------------------------------------------------------------------------------------- !!
  !>
  !! write snapshot
  !<
  !! ----
  subroutine output__write_snap( it )

    integer, intent(in) :: it


    call pwatch__on( "output__write_snap" )

    if( xz_v%sw ) call wbuf_xz_v(it)
    if( xz_u%sw ) call wbuf_xz_u(it)


    call pwatch__off( "output__write_snap" )

  end subroutine output__write_snap


  !! --------------------------------------------------------------------------------------------------------------------------- !!
  subroutine wbuf_xz_v(it)
    integer :: it
    integer :: i, k
    integer :: ii, kk
    real(SP), allocatable :: buf(:,:)

    if( mod( it-1, ntdec_s ) /= 0 ) return

    if( .not. allocated(buf) ) then
       allocate(buf(nxs,nzs))
    end if

    buf(:,:) = 0.0
    do ii = is0, is1
       do kk= ks0, ks1
          k = kk * kdec - kdec/2
          i = ii * idec - idec/2

          buf(ii,kk) = Vy(k,i) * UC * M0

       end do
    end do

    if( snp_format == 'native' ) then
       call write_reduce_array2d_r( nxs, nzs, xz_v%ionode, xz_v%io, buf )
    else
       call write_reduce_array2d_r_nc( it, 1, nxs, nzs, xz_v, buf )
    end if

  end subroutine wbuf_xz_v
  !! --------------------------------------------------------------------------------------------------------------------------- !!

  !! --------------------------------------------------------------------------------------------------------------------------- !!
  subroutine wbuf_xz_u(it)
    integer :: it
    integer :: i, k
    integer :: ii, kk

    if( .not. allocated(buf_u) ) then

    end if


    do ii = is0, is1
       do kk= ks0, ks1
          k = kk * kdec - kdec/2
          i = ii * idec - idec/2

          buf_u(ii,kk) = buf_u(ii,kk) +  Vy(k,i) * UC * M0 * dt

       end do
    end do

    if( mod( it-1, ntdec_s ) == 0 ) then

       if( snp_format == 'native' ) then
          call write_reduce_array2d_r( nxs, nzs, xz_u%ionode, xz_u%io, buf_u )
       else
          call write_reduce_array2d_r_nc( it, 1, nxs, nzs, xz_u, buf_u )
       end if

    end if

  end subroutine wbuf_xz_u
  !! --------------------------------------------------------------------------------------------------------------------------- !!

  !! --------------------------------------------------------------------------------------------------------------------------- !!
  !>
  !! write 2d array with MPI
  !<
  !! --------------------------------------------------------------------------------------------------------------------------- !!
  subroutine write_reduce_array2d_r_nc( it, vid, nx1, nx2, hdr, array )

    integer,   intent(in) :: it
    integer,   intent(in) :: vid
    integer,   intent(in) :: nx1, nx2
    type(snp), intent(inout) :: hdr
    real(SP),  intent(in) :: array(nx1,nx2)

    real(SP) :: sbuf(nx1*nx2)
    real(SP) :: rbuf(nx1*nx2)
    integer  :: ierr
    integer :: count(3)
    integer :: start(3)

    !! prepare send buffer
    sbuf = reshape( array, shape(sbuf) )

    !! gather to io_node
    call mpi_reduce( sbuf, rbuf, nx1*nx2, MPI_REAL, MPI_SUM, hdr%ionode, mpi_comm_world, ierr )

    !! write
    if( myid == hdr%ionode ) then
       count = (/ nxs, nzs, 1/)
       start = (/ 1, 1, it/ntdec_s+1 /)
       call nc_chk( nf90_put_var( hdr%io, hdr%varid(vid), reshape(rbuf,shape(array)), start, count ))
       call nc_chk( nf90_put_var( hdr%io, hdr%vid_t, it*dt, start=(/ it/ntdec_s+1 /) ) )
       hdr%vmax(vid) = max( hdr%vmax(vid), maxval(rbuf) )
       hdr%vmin(vid) = min( hdr%vmin(vid), minval(rbuf) )
    end if


  end subroutine write_reduce_array2d_r_nc
  !! --------------------------------------------------------------------------------------------------------------------------- !!

  !! --------------------------------------------------------------------------------------------------------------------------- !!
  !>
  !! write waveform
  !<
  !! ----
  subroutine output__store_wav(it)

    integer, intent(in) :: it
    integer :: i, itw

    if( .not. sw_wav ) return

    call pwatch__on( "output__write_wav" )


    if( it == 1 ) then
       allocate( uy(nst) )
       uy(:) = 0.0
    end if

    !! integrate waveform
    if( sw_wav_u ) then
       do i=1, nst
          uy(i) = uy(i) + Vy( kst(i), ist(i) ) * dt
       end do
    end if


    !! output
    if( mod( it-1, ntdec_w ) == 0 ) then
       itw = (it-1)/ntdec_w + 1
       if( sw_wav_v ) then
          do i=1, nst
             vyst(itw,i) =   Vy( kst(i), ist(i) ) * M0 * UC * 1e9 !! [nm/s]
          end do
       end if

       if( sw_wav_u ) then
          do i=1, nst
             uyst(itw,i) = uy(i) * M0 * UC * 1e9                          !! [nm]
          end do
       end if
    end if

    call pwatch__off( "output__write_wav" )

  end subroutine output__store_wav
  !! --------------------------------------------------------------------------------------------------------------------------- !!

  !! --------------------------------------------------------------------------------------------------------------------------- !!
  subroutine output__checkpoint( io )
    integer, intent(in) :: io
    !! ----

    write( io ) xz_v, xz_u
    write( io ) sw_wav, sw_wav_u, sw_wav_v

    write( io ) ntdec_s
    write( io ) idec,kdec

    write( io ) nxs, nzs
    write( io ) xsnp(1:nxs)
    write( io ) zsnp(1:nzs)

    write( io ) is0, is1, ks0, ks1
    write( io ) r20x, r20z

    write( io ) buf_u(is0:is1,ks0:ks1)

    write( io ) snp_format

    if( sw_wav ) then
       write( io ) ntdec_w
       write( io ) nst
       write( io ) ntw

       if( nst > 0 ) then
          write( io ) xst(1:nst)
          write( io ) zst(1:nst)
          write( io ) ist(1:nst)
          write( io ) kst(1:nst)
          write( io ) stlo(1:nst)
          write( io ) stla(1:nst)
          write( io ) stnm(1:nst)

          write( io ) vyst(1:ntw,1:nst)
          write( io ) uyst(1:ntw,1:nst)
          write( io ) sh(1:2,1:nst)
          write( io ) uy(1:nst)
       end if

    end if


  end subroutine output__checkpoint
  !! --------------------------------------------------------------------------------------------------------------------------- !!
  !! --------------------------------------------------------------------------------------------------------------------------- !!
  subroutine output__restart( io )
    integer, intent(in) :: io
    !! ----


    read( io ) xz_v, xz_u
    read( io ) sw_wav, sw_wav_u, sw_wav_v

    read( io ) ntdec_s
    read( io ) idec, kdec

    read( io ) nxs, nzs

    allocate( xsnp(1:nxs) )
    allocate( zsnp(1:nzs) )
    read( io ) xsnp(1:nxs)
    read( io ) zsnp(1:nzs)

    read( io ) is0, is1, ks0, ks1
    read( io ) r20x, r20z

    allocate( buf_u(nxs,nzs) )
    read( io ) buf_u(is0:is1,ks0:ks1)

    read( io ) snp_format

    if( sw_wav ) then
       read( io ) ntdec_w
       read( io ) nst
       read( io ) ntw

       if( nst > 0 ) then
          allocate( xst(nst), zst(nst) )
          allocate( ist(nst), kst(nst) )
          allocate( stnm(nst) )
          allocate( stlo(nst), stla(nst) )

          read( io ) xst(1:nst)
          read( io ) zst(1:nst)
          read( io ) ist(1:nst)
          read( io ) kst(1:nst)
          read( io ) stlo(1:nst)
          read( io ) stla(1:nst)
          read( io ) stnm(1:nst)

          allocate( vyst(ntw,nst) )
          allocate( uyst(ntw,nst) )
          allocate( uy(nst) )
          allocate( sh(2,nst) )
          read( io ) vyst(1:ntw,1:nst)
          read( io ) uyst(1:ntw,1:nst)
          read( io ) sh(1:2,1:nst)
          read( io ) uy(1:nst)
       end if

    end if

    if( snp_format == 'native' ) then
#ifdef _ES
       if( xz_v%sw .and. myid == xz_v%ionode ) then
          open( xz_v%io, file=trim(odir)//'/'//trim(title) //'.xz.v.snp', &
               position='append', form='unformatted', status='old' )
       end if
       if( xz_u%sw .and. myid == xz_u%ionode ) then
          open( xz_u%io, file=trim(odir)//'/'//trim(title) //'.xz.u.snp', &
               position='append', form='unformatted', status='old' )
       end if
#else
       if( xz_v%sw .and. myid == xz_v%ionode ) then
          open( xz_v%io, file=trim(odir)//'/'//trim(title) //'.xz.v.snp', &
               access='stream', position='append', form='unformatted', status='old' )
       end if
       if( xz_u%sw .and. myid == xz_u%ionode ) then
          open( xz_u%io, file=trim(odir)//'/'//trim(title) //'.xz.u.snp', &
               access='stream', position='append', form='unformatted', status='old' )
       end if
#endif

    else
       if( xz_v%sw .and. myid == xz_v%ionode ) then
          call nc_chk( nf90_open( trim(odir)//'/'//trim(title) //'.xz.v.nc', NF90_WRITE, xz_v%io ) )
       end if
       if( xz_u%sw .and. myid == xz_u%ionode ) then
          call nc_chk( nf90_open( trim(odir)//'/'//trim(title) //'.xz.u.nc', NF90_WRITE, xz_u%io ) )
       end if
    end if

  end subroutine output__restart
  !! --------------------------------------------------------------------------------------------------------------------------- !!
  subroutine output__closefiles

    if( snp_format == 'native' ) then
       if( xz_v%sw .and. myid == xz_v%ionode ) close( xz_v%io )
       if( xz_u%sw .and. myid == xz_u%ionode ) close( xz_u%io )
    else

       if( xz_v%sw .and. myid == xz_v%ionode ) then
          ! set max & min for each vars
          call nc_chk( nf90_redef( xz_v%io ) )
          call nc_chk( nf90_put_att( xz_v%io, xz_v%varid(1), 'actual_range', (/xz_v%vmin(1), xz_v%vmax(1)/) ) )
          call nc_chk( nf90_close( xz_v%io ) )

       end if

       if( xz_u%sw  .and. myid == xz_u%ionode  ) then

          ! set max & min for each vars
          call nc_chk( nf90_redef( xz_u%io ) )
          call nc_chk( nf90_put_att( xz_u%io, xz_u%varid(1), 'actual_range', (/xz_u%vmin(1), xz_u%vmax(1)/) ) )
          call nc_chk( nf90_close( xz_u%io ) )

       end if


    end if

  end subroutine output__closefiles

  !! --------------------------------------------------------------------------------------------------------------------------- !!
  !>
  !! An internal subroutine to check error in netcdf function calls
  !<
  !! --
  subroutine nc_chk( ierr )

    integer, intent(in) :: ierr
    !! ----

#ifdef _NETCDF
    if( ierr /= NF90_NOERR )  write(STDERR,*) NF90_STRERROR( ierr )
#endif

  end subroutine nc_chk
  !! --------------------------------------------------------------------------------------------------------------------------- !!

end module m_output
!! ----------------------------------------------------------------------------------------------------------------------------- !!
