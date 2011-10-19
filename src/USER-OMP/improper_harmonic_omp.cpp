/* ----------------------------------------------------------------------
   LAMMPS - Large-scale Atomic/Molecular Massively Parallel Simulator
   http://lammps.sandia.gov, Sandia National Laboratories
   Steve Plimpton, sjplimp@sandia.gov

   Copyright (2003) Sandia Corporation.  Under the terms of Contract
   DE-AC04-94AL85000 with Sandia Corporation, the U.S. Government retains
   certain rights in this software.  This software is distributed under 
   the GNU General Public License.

   See the README file in the top-level LAMMPS directory.
------------------------------------------------------------------------- */

/* ----------------------------------------------------------------------
   Contributing author: Axel Kohlmeyer (Temple U)
------------------------------------------------------------------------- */

#include "lmptype.h"
#include "mpi.h"
#include "math.h"
#include "improper_harmonic_omp.h"
#include "atom.h"
#include "comm.h"
#include "neighbor.h"
#include "domain.h"
#include "force.h"
#include "update.h"
#include "error.h"

using namespace LAMMPS_NS;

#define TOLERANCE 0.05
#define SMALL     0.001

/* ---------------------------------------------------------------------- */

void ImproperHarmonicOMP::compute(int eflag, int vflag)
{

  if (eflag || vflag) {
    ev_setup(eflag,vflag);
  } else evflag = 0;

  const int nall = atom->nlocal + atom->nghost;
  const int nthreads = comm->nthreads;
  const int inum = neighbor->nimproperlist;

#if defined(_OPENMP)
#pragma omp parallel default(shared)
#endif
  {
    int ifrom, ito, tid;

    loop_setup_thr(ifrom, ito, tid, inum, nthreads);
    ThrData *thr = fix->get_thr(tid);
    ev_setup_thr(eflag, vflag, nall, eatom, vatom, thr);

    if (evflag) {
      if (eflag) {
	if (force->newton_bond) eval<1,1,1>(ifrom, ito, thr);
	else eval<1,1,0>(ifrom, ito, thr);
      } else {
	if (force->newton_bond) eval<1,0,1>(ifrom, ito, thr);
	else eval<1,0,0>(ifrom, ito, thr);
      }
    } else {
      if (force->newton_bond) eval<0,0,1>(ifrom, ito, thr);
      else eval<0,0,0>(ifrom, ito, thr);
    }

    reduce_thr(eflag, vflag, thr);
  } // end of omp parallel region
}

template <int EVFLAG, int EFLAG, int NEWTON_BOND>
void ImproperHarmonicOMP::eval(int nfrom, int nto, ThrData * const thr)
{
  int i1,i2,i3,i4,n,type;
  double vb1x,vb1y,vb1z,vb2x,vb2y,vb2z,vb3x,vb3y,vb3z;
  double eimproper,f1[3],f2[3],f3[3],f4[3];
  double ss1,ss2,ss3,r1,r2,r3,c0,c1,c2,s1,s2;
  double s12,c,s,domega,a,a11,a22,a33,a12,a13,a23;
  double sx2,sy2,sz2;

  eimproper = 0.0;

  const double * const * const x = atom->x;
  double * const * const f = thr->get_f();
  const int * const * const improperlist = neighbor->improperlist;
  const int nlocal = atom->nlocal;

  for (n = nfrom; n < nto; n++) {
    i1 = improperlist[n][0];
    i2 = improperlist[n][1];
    i3 = improperlist[n][2];
    i4 = improperlist[n][3];
    type = improperlist[n][4];

    // geometry of 4-body

    vb1x = x[i1][0] - x[i2][0];
    vb1y = x[i1][1] - x[i2][1];
    vb1z = x[i1][2] - x[i2][2];
    domain->minimum_image(vb1x,vb1y,vb1z);

    vb2x = x[i3][0] - x[i2][0];
    vb2y = x[i3][1] - x[i2][1];
    vb2z = x[i3][2] - x[i2][2];
    domain->minimum_image(vb2x,vb2y,vb2z);

    vb3x = x[i4][0] - x[i3][0];
    vb3y = x[i4][1] - x[i3][1];
    vb3z = x[i4][2] - x[i3][2];
    domain->minimum_image(vb3x,vb3y,vb3z);

    ss1 = 1.0 / (vb1x*vb1x + vb1y*vb1y + vb1z*vb1z);
    ss2 = 1.0 / (vb2x*vb2x + vb2y*vb2y + vb2z*vb2z);
    ss3 = 1.0 / (vb3x*vb3x + vb3y*vb3y + vb3z*vb3z);
        
    r1 = sqrt(ss1);
    r2 = sqrt(ss2);
    r3 = sqrt(ss3);
        
    // sin and cos of angle
        
    c0 = (vb1x * vb3x + vb1y * vb3y + vb1z * vb3z) * r1 * r3;
    c1 = (vb1x * vb2x + vb1y * vb2y + vb1z * vb2z) * r1 * r2;
    c2 = -(vb3x * vb2x + vb3y * vb2y + vb3z * vb2z) * r3 * r2;

    s1 = 1.0 - c1*c1;
    if (s1 < SMALL) s1 = SMALL;
    s1 = 1.0 / s1;

    s2 = 1.0 - c2*c2;
    if (s2 < SMALL) s2 = SMALL;
    s2 = 1.0 / s2;

    s12 = sqrt(s1*s2);
    c = (c1*c2 + c0) * s12;

    // error check

    if (c > 1.0 + TOLERANCE || c < (-1.0 - TOLERANCE)) {
      int me = comm->me;

      if (screen) {
	char str[128];
	sprintf(str,"Improper problem: %d/%d " BIGINT_FORMAT " %d %d %d %d",
		me,thr->get_tid(),update->ntimestep,
		atom->tag[i1],atom->tag[i2],atom->tag[i3],atom->tag[i4]);
	error->warning(FLERR,str,0);
	fprintf(screen,"  1st atom: %d %g %g %g\n",
		me,x[i1][0],x[i1][1],x[i1][2]);
	fprintf(screen,"  2nd atom: %d %g %g %g\n",
		me,x[i2][0],x[i2][1],x[i2][2]);
	fprintf(screen,"  3rd atom: %d %g %g %g\n",
		me,x[i3][0],x[i3][1],x[i3][2]);
	fprintf(screen,"  4th atom: %d %g %g %g\n",
		me,x[i4][0],x[i4][1],x[i4][2]);
      }
    }
    
    if (c > 1.0) c = 1.0;
    if (c < -1.0) c = -1.0;

    s = sqrt(1.0 - c*c);
    if (s < SMALL) s = SMALL;

    // force & energy

    domega = acos(c) - chi[type];
    a = k[type] * domega;

    if (EFLAG) eimproper = a*domega;

    a = -a * 2.0/s;
    c = c * a;
    s12 = s12 * a;
    a11 = c*ss1*s1;
    a22 = -ss2 * (2.0*c0*s12 - c*(s1+s2));
    a33 = c*ss3*s2;
    a12 = -r1*r2*(c1*c*s1 + c2*s12);
    a13 = -r1*r3*s12;
    a23 = r2*r3*(c2*c*s2 + c1*s12);

    sx2  = a22*vb2x + a23*vb3x + a12*vb1x;
    sy2  = a22*vb2y + a23*vb3y + a12*vb1y;
    sz2  = a22*vb2z + a23*vb3z + a12*vb1z;

    f1[0] = a12*vb2x + a13*vb3x + a11*vb1x;
    f1[1] = a12*vb2y + a13*vb3y + a11*vb1y;
    f1[2] = a12*vb2z + a13*vb3z + a11*vb1z;

    f2[0] = -sx2 - f1[0];
    f2[1] = -sy2 - f1[1];
    f2[2] = -sz2 - f1[2];

    f4[0] = a23*vb2x + a33*vb3x + a13*vb1x;
    f4[1] = a23*vb2y + a33*vb3y + a13*vb1y;
    f4[2] = a23*vb2z + a33*vb3z + a13*vb1z;

    f3[0] = sx2 - f4[0];
    f3[1] = sy2 - f4[1];
    f3[2] = sz2 - f4[2];

    // apply force to each of 4 atoms

    if (NEWTON_BOND || i1 < nlocal) {
      f[i1][0] += f1[0];
      f[i1][1] += f1[1];
      f[i1][2] += f1[2];
    }

    if (NEWTON_BOND || i2 < nlocal) {
      f[i2][0] += f2[0];
      f[i2][1] += f2[1];
      f[i2][2] += f2[2];
    }

    if (NEWTON_BOND || i3 < nlocal) {
      f[i3][0] += f3[0];
      f[i3][1] += f3[1];
      f[i3][2] += f3[2];
    }

    if (NEWTON_BOND || i4 < nlocal) {
      f[i4][0] += f4[0];
      f[i4][1] += f4[1];
      f[i4][2] += f4[2];
    }

    if (EVFLAG)
      ev_tally_thr(this,i1,i2,i3,i4,nlocal,NEWTON_BOND,eimproper,f1,f3,f4,
		   vb1x,vb1y,vb1z,vb2x,vb2y,vb2z,vb3x,vb3y,vb3z,thr);
  }
}
