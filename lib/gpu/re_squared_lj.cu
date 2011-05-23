// **************************************************************************
//                               re_squared_lj.cu
//                             -------------------
//                               W. Michael Brown
//
//  Device code for RE-Squared - Lennard-Jones potential acceleration
//
// __________________________________________________________________________
//    This file is part of the LAMMPS Accelerator Library (LAMMPS_AL)
// __________________________________________________________________________
//
//    begin                : Fri May 06 2011
//    email                : brownw@ornl.gov
// ***************************************************************************/

#ifndef RE_SQUARED_LJ_CU
#define RE_SQUARED_LJ_CU

#ifdef NV_KERNEL
#include "ellipsoid_extra.h"
#endif

#define SBBITS 30
#define NEIGHMASK 0x3FFFFFFF
__inline int sbmask(int j) { return j >> SBBITS & 3; }


__kernel void kernel_ellipsoid_sphere(__global numtyp4* x_,__global numtyp4 *q,
                   __global numtyp4* shape, __global numtyp4* well, 
                   __global numtyp *splj, __global numtyp2* sig_eps,
                   const int ntypes, __global numtyp *lshape, 
                   __global int *dev_nbor, const int stride, 
                   __global acctyp4 *ans, const int astride, 
                   __global acctyp *engv, __global int *err_flag, 
                   const int eflag, const int vflag, const int inum,
                   const int nall, const int t_per_atom) {
  int tid=THREAD_ID_X;
  int ii=mul24((int)BLOCK_ID_X,(int)(BLOCK_SIZE_X)/t_per_atom);
  ii+=tid/t_per_atom;
  int offset=tid%t_per_atom;

  __local numtyp sp_lj[4];
  sp_lj[0]=splj[0];    
  sp_lj[1]=splj[1];    
  sp_lj[2]=splj[2];    
  sp_lj[3]=splj[3];
  
  __local numtyp b_alpha, cr60, solv_f_a, solv_f_r;
  b_alpha=(numtyp)45.0/(numtyp)56.0;
  cr60=pow((numtyp)60.0,(numtyp)1.0/(numtyp)3.0);    
  solv_f_a = (numtyp)3.0/((numtyp)16.0*atan((numtyp)1.0)*-(numtyp)36.0);
  solv_f_r = (numtyp)3.0/((numtyp)16.0*atan((numtyp)1.0)*(numtyp)2025.0);

  acctyp energy=(acctyp)0;
  acctyp4 f;
  f.x=(acctyp)0;
  f.y=(acctyp)0;
  f.z=(acctyp)0;
  acctyp4 tor;
  tor.x=(acctyp)0;
  tor.y=(acctyp)0;
  tor.z=(acctyp)0;
  acctyp virial[6];
  for (int i=0; i<6; i++)
    virial[i]=(acctyp)0;

  if (ii<inum) {
    __global int *nbor=dev_nbor+ii;
    int i=*nbor;
    nbor+=stride;
    int numj=*nbor;
    nbor+=stride;
    __global int *nbor_end=nbor+mul24(stride,numj);
    nbor+=mul24(offset,stride);
    int n_stride=mul24(t_per_atom,stride);
  
    numtyp4 ix=x_[i];
    int itype=ix.w;

    numtyp a[9];       // Rotation matrix (lab->body)
    numtyp aTe[9];     // A'*E
    numtyp lA_0[9], lA_1[9], lA_2[9]; // -A*rotation generator (x,y, or z)
    numtyp4 ishape;
    
    ishape=shape[itype];

    {
      gpu_quat_to_mat_trans(q,i,a);
      gpu_transpose_times_diag3(a,well[itype],aTe);
      gpu_rotation_generator_x(a,lA_0);
      gpu_rotation_generator_y(a,lA_1);
      gpu_rotation_generator_z(a,lA_2);
    }

    numtyp factor_lj;
    for ( ; nbor<nbor_end; nbor+=n_stride) {
      int j=*nbor;
      factor_lj = sp_lj[sbmask(j)];
      j &= NEIGHMASK;

      numtyp4 jx=x_[j];
      int jtype=jx.w;

      // Compute r12
      numtyp r[3], rhat[3];
      numtyp rnorm;
      r[0] = jx.x-ix.x;
      r[1] = jx.y-ix.y;
      r[2] = jx.z-ix.z;
      rnorm = gpu_dot3(r,r);
      rnorm = sqrt(rnorm);
      rhat[0] = r[0]/rnorm;
      rhat[1] = r[1]/rnorm;
      rhat[2] = r[2]/rnorm;

      numtyp sigma, epsilon;
      int mtype=mul24(ntypes,itype)+jtype;
      sigma = sig_eps[mtype].x;
      epsilon = sig_eps[mtype].y*factor_lj;

      numtyp aTs[9]; 
      numtyp4 scorrect;
      numtyp half_sigma=sigma / (numtyp)2.0;
      scorrect.x = ishape.x+half_sigma;
      scorrect.y = ishape.y+half_sigma;
      scorrect.z = ishape.z+half_sigma;
      scorrect.x = scorrect.x * scorrect.x / (numtyp)2.0;
      scorrect.y = scorrect.y * scorrect.y / (numtyp)2.0;
      scorrect.z = scorrect.z * scorrect.z / (numtyp)2.0;
      gpu_transpose_times_diag3(a,scorrect,aTs);

      // energy

      numtyp gamma[9], s[3];
      gpu_times3(aTs,a,gamma);
      gpu_mldivide3(gamma,rhat,s,err_flag);

      numtyp sigma12 = (numtyp)1.0/sqrt((numtyp)0.5*gpu_dot3(s,rhat));
      numtyp temp[9], w[3];
      gpu_times3(aTe,a,temp);
      temp[0] += (numtyp)1.0;
      temp[4] += (numtyp)1.0;
      temp[8] += (numtyp)1.0;
      gpu_mldivide3(temp,rhat,w,err_flag);

      numtyp h12 = rnorm-sigma12;
      numtyp chi = (numtyp)2.0*gpu_dot3(rhat,w);
      numtyp sigh = sigma/h12;
      numtyp tprod = chi*sigh;

      numtyp Ua, Ur;
      numtyp h12p3 = h12*h12*h12;
      numtyp sigmap3 = pow(sigma,(numtyp)3.0);
      numtyp stemp = h12/(numtyp)2.0;
      Ua = (ishape.x+stemp)*(ishape.y+stemp)*(ishape.z+stemp)*h12p3/(numtyp)8.0;
      Ua = ((numtyp)1.0+(numtyp)3.0*tprod)*lshape[itype]/Ua;
      Ua = epsilon*Ua*sigmap3*solv_f_a;
    
      stemp = h12/cr60;
      Ur = (ishape.x+stemp)*(ishape.y+stemp)*(ishape.z+stemp)*h12p3/
           (numtyp)60.0;
      Ur = ((numtyp)1.0+b_alpha*tprod)*lshape[itype]/Ur;
      numtyp sigh6=sigh*sigh*sigh;
      sigh6*=sigh6;
      Ur = epsilon*Ur*sigmap3*sigh6*solv_f_r;

      energy+=Ua+Ur;

      // force

      numtyp fourw[3], spr[3];
      numtyp sec = sigma*chi;
      numtyp sigma12p3 = pow(sigma12,(numtyp)3.0);
      fourw[0] = (numtyp)4.0*w[0];
      fourw[1] = (numtyp)4.0*w[1];
      fourw[2] = (numtyp)4.0*w[2];
      spr[0] = (numtyp)0.5*sigma12p3*s[0];
      spr[1] = (numtyp)0.5*sigma12p3*s[1];
      spr[2] = (numtyp)0.5*sigma12p3*s[2];

      stemp = (numtyp)1.0/(ishape.x*(numtyp)2.0+h12)+
              (numtyp)1.0/(ishape.y*(numtyp)2.0+h12)+
              (numtyp)1.0/(ishape.z*(numtyp)2.0+h12)+
              (numtyp)3.0/h12;
      numtyp hsec = h12+(numtyp)3.0*sec;
      numtyp dspu = (numtyp)1.0/h12-(numtyp)1.0/hsec+stemp;
      numtyp pbsu = (numtyp)3.0*sigma/hsec;
  
      stemp = (numtyp)1.0/(ishape.x*cr60+h12)+
              (numtyp)1.0/(ishape.y*cr60+h12)+
              (numtyp)1.0/(ishape.z*cr60+h12)+
              (numtyp)3.0/h12;
      hsec = h12+b_alpha*sec;
      numtyp dspr = (numtyp)7.0/h12-(numtyp)1.0/hsec+stemp;
      numtyp pbsr = b_alpha*sigma/hsec;
  
      #pragma unroll
      for (int i=0; i<3; i++) {
        numtyp u[3];
        u[0] = -rhat[i]*rhat[0];
        u[1] = -rhat[i]*rhat[1];
        u[2] = -rhat[i]*rhat[2];
        u[i] += (numtyp)1.0;
        u[0] /= rnorm;
        u[1] /= rnorm;
        u[2] /= rnorm;
        numtyp dchi = gpu_dot3(u,fourw);
        numtyp dh12 = rhat[i]+gpu_dot3(u,spr);
        numtyp dUa = pbsu*dchi-dh12*dspu;
        numtyp dUr = pbsr*dchi-dh12*dspr;
        numtyp force=dUr*Ur+dUa*Ua;
        if (i==0) {
          f.x+=force;
          if (vflag>0)
            virial[0]+=-r[0]*force;
        } else if (i==1) {
          f.y+=force;
          if (vflag>0) {
            virial[1]+=-r[1]*force;
            virial[3]+=-r[0]*force;
          }
        } else {
          f.z+=force;
          if (vflag>0) {
            virial[2]+=-r[2]*force;
            virial[4]+=-r[0]*force;
            virial[5]+=-r[1]*force;
          }
        }

      }
    
      // torque on i
      numtyp fwae[3];
      gpu_row_times3(fourw,aTe,fwae);
      {
        numtyp tempv[3], p[3], lAtwo[9];
        gpu_times_column3(lA_0,rhat,p);
        gpu_times_column3(lA_0,w,tempv);
        numtyp dchi = -gpu_dot3(fwae,tempv);
        gpu_times3(aTs,lA_0,lAtwo);
        gpu_times_column3(lAtwo,spr,tempv);
        numtyp dh12 = -gpu_dot3(s,tempv);
        numtyp dUa = pbsu*dchi-dh12*dspu;
        numtyp dUr = pbsr*dchi-dh12*dspr;
        tor.x -= (dUa*Ua+dUr*Ur);
      }

      {
        numtyp tempv[3], p[3], lAtwo[9];
        gpu_times_column3(lA_1,rhat,p);
        gpu_times_column3(lA_1,w,tempv);
        numtyp dchi = -gpu_dot3(fwae,tempv);
        gpu_times3(aTs,lA_1,lAtwo);
        gpu_times_column3(lAtwo,spr,tempv);
        numtyp dh12 = -gpu_dot3(s,tempv);
        numtyp dUa = pbsu*dchi-dh12*dspu;
        numtyp dUr = pbsr*dchi-dh12*dspr;
        tor.y -= (dUa*Ua+dUr*Ur);
      }

      {
        numtyp tempv[3], p[3], lAtwo[9];
        gpu_times_column3(lA_2,rhat,p);
        gpu_times_column3(lA_2,w,tempv);
        numtyp dchi = -gpu_dot3(fwae,tempv);
        gpu_times3(aTs,lA_2,lAtwo);
        gpu_times_column3(lAtwo,spr,tempv);
        numtyp dh12 = -gpu_dot3(s,tempv);
        numtyp dUa = pbsu*dchi-dh12*dspu;
        numtyp dUr = pbsr*dchi-dh12*dspr;
        tor.z -= (dUa*Ua+dUr*Ur);
      }

    } // for nbor
  } // if ii
  
  // Reduce answers
  if (t_per_atom>1) {
    __local acctyp red_acc[7][BLOCK_PAIR];
    
    red_acc[0][tid]=f.x;
    red_acc[1][tid]=f.y;
    red_acc[2][tid]=f.z;
    red_acc[3][tid]=tor.x;
    red_acc[4][tid]=tor.y;
    red_acc[5][tid]=tor.z;

    for (unsigned int s=t_per_atom/2; s>0; s>>=1) {
      if (offset < s) {
        for (int r=0; r<6; r++)
          red_acc[r][tid] += red_acc[r][tid+s];
      }
    }
    
    f.x=red_acc[0][tid];
    f.y=red_acc[1][tid];
    f.z=red_acc[2][tid];
    tor.x=red_acc[3][tid];
    tor.y=red_acc[4][tid];
    tor.z=red_acc[5][tid];

    if (eflag>0 || vflag>0) {
      for (int r=0; r<6; r++)
        red_acc[r][tid]=virial[r];
      red_acc[6][tid]=energy;

      for (unsigned int s=t_per_atom/2; s>0; s>>=1) {
        if (offset < s) {
          for (int r=0; r<7; r++)
            red_acc[r][tid] += red_acc[r][tid+s];
        }
      }
    
      for (int r=0; r<6; r++)
        virial[r]=red_acc[r][tid];
      energy=red_acc[6][tid];
    }
  }

  // Store answers
  if (ii<inum && offset==0) {
    __global acctyp *ap1=engv+ii;
    if (eflag>0) {
      *ap1+=energy;
      ap1+=astride;
    }
    if (vflag>0) {
      for (int i=0; i<6; i++) {
        *ap1+=virial[i];
        ap1+=astride;
      }
    }
    acctyp4 old=ans[ii];
    old.x+=f.x;
    old.y+=f.y;
    old.z+=f.z;
    ans[ii]=old;
    
    old=ans[ii+astride];
    old.x+=tor.x;
    old.y+=tor.y;
    old.z+=tor.z;
    ans[ii+astride]=old;
  } // if ii

}

__kernel void kernel_sphere_ellipsoid(__global numtyp4 *x_,__global numtyp4 *q,
                               __global numtyp4* shape,__global numtyp4* well, 
                               __global numtyp *splj, __global numtyp2* sig_eps, 
                               const int ntypes, __global numtyp *lshape, 
                               __global int *dev_nbor, const int stride, 
                               __global acctyp4 *ans, __global acctyp *engv, 
                               __global int *err_flag, const int eflag, 
                               const int vflag,const int start, const int inum, 
                               const int nall, const int t_per_atom) {
  int tid=THREAD_ID_X;
  int ii=mul24((int)BLOCK_ID_X,(int)(BLOCK_SIZE_X)/t_per_atom);
  ii+=tid/t_per_atom+start;
  int offset=tid%t_per_atom;

  __local numtyp sp_lj[4];
  sp_lj[0]=splj[0];    
  sp_lj[1]=splj[1];    
  sp_lj[2]=splj[2];    
  sp_lj[3]=splj[3];
  
  __local numtyp b_alpha, cr60, solv_f_a, solv_f_r;
  b_alpha=(numtyp)45.0/(numtyp)56.0;
  cr60=pow((numtyp)60.0,(numtyp)1.0/(numtyp)3.0);    
  solv_f_a = (numtyp)3.0/((numtyp)16.0*atan((numtyp)1.0)*-(numtyp)36.0);
  solv_f_r = (numtyp)3.0/((numtyp)16.0*atan((numtyp)1.0)*(numtyp)2025.0);

  acctyp energy=(acctyp)0;
  acctyp4 f;
  f.x=(acctyp)0;
  f.y=(acctyp)0;
  f.z=(acctyp)0;
  acctyp virial[6];
  for (int i=0; i<6; i++)
    virial[i]=(acctyp)0;

  if (ii<inum) {
    __global int *nbor=dev_nbor+ii;
    int j=*nbor;
    nbor+=stride;
    int numj=*nbor;
    nbor+=stride;
    __global int *nbor_end=nbor+mul24(stride,numj);
    nbor+=mul24(offset,stride);
    int n_stride=mul24(t_per_atom,stride);
  
    numtyp4 jx=x_[j];
    int jtype=jx.w;

    numtyp factor_lj;
    for ( ; nbor<nbor_end; nbor+=n_stride) {
      int i=*nbor;
      factor_lj = sp_lj[sbmask(i)];
      i &= NEIGHMASK;

      numtyp4 ix=x_[i];
      int itype=ix.w;

      numtyp a[9];       // Rotation matrix (lab->body)
      numtyp aTe[9];     // A'*E
      numtyp4 ishape;
    
      ishape=shape[itype];
      gpu_quat_to_mat_trans(q,i,a);
      gpu_transpose_times_diag3(a,well[itype],aTe);

      // Compute r12
      numtyp r[3], rhat[3];
      numtyp rnorm;
      r[0] = ix.x-jx.x;
      r[1] = ix.y-jx.y;
      r[2] = ix.z-jx.z;
      rnorm = gpu_dot3(r,r);
      rnorm = sqrt(rnorm);
      rhat[0] = r[0]/rnorm;
      rhat[1] = r[1]/rnorm;
      rhat[2] = r[2]/rnorm;

      numtyp sigma, epsilon;
      int mtype=mul24(ntypes,itype)+jtype;
      sigma = sig_eps[mtype].x;
      epsilon = sig_eps[mtype].y*factor_lj;

      numtyp aTs[9]; 
      numtyp4 scorrect;
      numtyp half_sigma=sigma / (numtyp)2.0;
      scorrect.x = ishape.x+half_sigma;
      scorrect.y = ishape.y+half_sigma;
      scorrect.z = ishape.z+half_sigma;
      scorrect.x = scorrect.x * scorrect.x / (numtyp)2.0;
      scorrect.y = scorrect.y * scorrect.y / (numtyp)2.0;
      scorrect.z = scorrect.z * scorrect.z / (numtyp)2.0;
      gpu_transpose_times_diag3(a,scorrect,aTs);
      
      // energy

      numtyp gamma[9], s[3];
      gpu_times3(aTs,a,gamma);
      gpu_mldivide3(gamma,rhat,s,err_flag);

      numtyp sigma12 = (numtyp)1.0/sqrt((numtyp)0.5*gpu_dot3(s,rhat));
      numtyp temp[9], w[3];
      gpu_times3(aTe,a,temp);
      temp[0] += (numtyp)1.0;
      temp[4] += (numtyp)1.0;
      temp[8] += (numtyp)1.0;
      gpu_mldivide3(temp,rhat,w,err_flag);

      numtyp h12 = rnorm-sigma12;
      numtyp chi = (numtyp)2.0*gpu_dot3(rhat,w);
      numtyp sigh = sigma/h12;
      numtyp tprod = chi*sigh;

      numtyp Ua, Ur;
      numtyp h12p3 = pow(h12,(numtyp)3.0);
      numtyp sigmap3 = pow(sigma,(numtyp)3.0);
      numtyp stemp = h12/(numtyp)2.0;
      Ua = (ishape.x+stemp)*(ishape.y+stemp)*(ishape.z+stemp)*h12p3/(numtyp)8.0;
      Ua = ((numtyp)1.0+(numtyp)3.0*tprod)*lshape[itype]/Ua;
      Ua = epsilon*Ua*sigmap3*solv_f_a;
    
      stemp = h12/cr60;
      Ur = (ishape.x+stemp)*(ishape.y+stemp)*(ishape.z+stemp)*h12p3/
           (numtyp)60.0;
      Ur = ((numtyp)1.0+b_alpha*tprod)*lshape[itype]/Ur;
      Ur = epsilon*Ur*sigmap3*pow(sigh,(numtyp)6.0)*solv_f_r;

      energy+=Ua+Ur;

      // force

      numtyp fourw[3], spr[3];
      numtyp sec = sigma*chi;
      numtyp sigma12p3 = pow(sigma12,(numtyp)3.0);
      fourw[0] = (numtyp)4.0*w[0];
      fourw[1] = (numtyp)4.0*w[1];
      fourw[2] = (numtyp)4.0*w[2];
      spr[0] = (numtyp)0.5*sigma12p3*s[0];
      spr[1] = (numtyp)0.5*sigma12p3*s[1];
      spr[2] = (numtyp)0.5*sigma12p3*s[2];

      stemp = (numtyp)1.0/(ishape.x*(numtyp)2.0+h12)+
              (numtyp)1.0/(ishape.y*(numtyp)2.0+h12)+
              (numtyp)1.0/(ishape.z*(numtyp)2.0+h12)+
              (numtyp)3.0/h12;
      numtyp hsec = h12+(numtyp)3.0*sec;
      numtyp dspu = (numtyp)1.0/h12-(numtyp)1.0/hsec+stemp;
      numtyp pbsu = (numtyp)3.0*sigma/hsec;
  
      stemp = (numtyp)1.0/(ishape.x*cr60+h12)+
              (numtyp)1.0/(ishape.y*cr60+h12)+
              (numtyp)1.0/(ishape.z*cr60+h12)+
              (numtyp)3.0/h12;
      hsec = h12+b_alpha*sec;
      numtyp dspr = (numtyp)7.0/h12-(numtyp)1.0/hsec+stemp;
      numtyp pbsr = b_alpha*sigma/hsec;
  
      #pragma unroll
      for (int i=0; i<3; i++) {
        numtyp u[3];
        u[0] = -rhat[i]*rhat[0];
        u[1] = -rhat[i]*rhat[1];
        u[2] = -rhat[i]*rhat[2];
        u[i] += (numtyp)1.0;
        u[0] /= rnorm;
        u[1] /= rnorm;
        u[2] /= rnorm;
        numtyp dchi = gpu_dot3(u,fourw);
        numtyp dh12 = rhat[i]+gpu_dot3(u,spr);
        numtyp dUa = pbsu*dchi-dh12*dspu;
        numtyp dUr = pbsr*dchi-dh12*dspr;
        numtyp force=dUr*Ur+dUa*Ua;
        if (i==0) {
          f.x+=force;
          if (vflag>0)
            virial[0]+=-r[0]*force;
        } else if (i==1) {
          f.y+=force;
          if (vflag>0) {
            virial[1]+=-r[1]*force;
            virial[3]+=-r[0]*force;
          }
        } else {
          f.z+=force;
          if (vflag>0) {
            virial[2]+=-r[2]*force;
            virial[4]+=-r[0]*force;
            virial[5]+=-r[1]*force;
          }
        }

      }
    
    } // for nbor
  } // if ii
  
  // Reduce answers
  if (t_per_atom>1) {
    __local acctyp red_acc[7][BLOCK_PAIR];
    
    red_acc[0][tid]=f.x;
    red_acc[1][tid]=f.y;
    red_acc[2][tid]=f.z;

    for (unsigned int s=t_per_atom/2; s>0; s>>=1) {
      if (offset < s) {
        for (int r=0; r<3; r++)
          red_acc[r][tid] += red_acc[r][tid+s];
      }
    }
    
    f.x=red_acc[0][tid];
    f.y=red_acc[1][tid];
    f.z=red_acc[2][tid];

    if (eflag>0 || vflag>0) {
      for (int r=0; r<6; r++)
        red_acc[r][tid]=virial[r];
      red_acc[6][tid]=energy;

      for (unsigned int s=t_per_atom/2; s>0; s>>=1) {
        if (offset < s) {
          for (int r=0; r<7; r++)
            red_acc[r][tid] += red_acc[r][tid+s];
        }
      }
    
      for (int r=0; r<6; r++)
        virial[r]=red_acc[r][tid];
      energy=red_acc[6][tid];
    }
  }

  // Store answers
  if (ii<inum && offset==0) {
    __global acctyp *ap1=engv+ii;
    if (eflag>0) {
      *ap1=energy;
      ap1+=inum;
    }
    if (vflag>0) {
      for (int i=0; i<6; i++) {
        *ap1=virial[i];
        ap1+=inum;
      }
    }
    ans[ii]=f;
  } // if ii
}

__kernel void kernel_lj(__global numtyp4 *x_, __global numtyp4 *lj1, 
                        __global numtyp4* lj3, const int lj_types, 
                        __global numtyp *gum, 
                        const int stride, __global int *dev_ij, 
                        __global acctyp4 *ans, __global acctyp *engv, 
                        __global int *err_flag, const int eflag, 
                        const int vflag, const int start, const int inum, 
                        const int nall, const int t_per_atom) {
  int tid=THREAD_ID_X;
  int ii=mul24((int)BLOCK_ID_X,(int)(BLOCK_SIZE_X)/t_per_atom);
  ii+=tid/t_per_atom+start;
  int offset=tid%t_per_atom;

  __local numtyp sp_lj[4];
  sp_lj[0]=gum[0];    
  sp_lj[1]=gum[1];    
  sp_lj[2]=gum[2];    
  sp_lj[3]=gum[3];    

  acctyp energy=(acctyp)0;
  acctyp4 f;
  f.x=(acctyp)0;
  f.y=(acctyp)0;
  f.z=(acctyp)0;
  acctyp virial[6];
  for (int i=0; i<6; i++)
    virial[i]=(acctyp)0;
  
  if (ii<inum) {
    __global int *nbor=dev_ij+ii;
    int i=*nbor;
    nbor+=stride;
    int numj=*nbor;
    nbor+=stride;
    __global int *list_end=nbor+mul24(stride,numj);
    nbor+=mul24(offset,stride);
    int n_stride=mul24(t_per_atom,stride);
  
    numtyp4 ix=x_[i];
    int itype=ix.w;

    numtyp factor_lj;
    for ( ; nbor<list_end; nbor+=n_stride) {
  
      int j=*nbor;
      factor_lj = sp_lj[sbmask(j)];
      j &= NEIGHMASK;

      numtyp4 jx=x_[j];
      int jtype=jx.w;

      // Compute r12
      numtyp delx = ix.x-jx.x;
      numtyp dely = ix.y-jx.y;
      numtyp delz = ix.z-jx.z;
      numtyp r2inv = delx*delx+dely*dely+delz*delz;
        
      int ii=itype*lj_types+jtype;
      if (r2inv<lj1[ii].z && lj1[ii].w==SPHERE_SPHERE) {
        r2inv=(numtyp)1.0/r2inv;
        numtyp r6inv = r2inv*r2inv*r2inv;
        numtyp force = r2inv*r6inv*(lj1[ii].x*r6inv-lj1[ii].y);
        force*=factor_lj;
      
        f.x+=delx*force;
        f.y+=dely*force;
        f.z+=delz*force;

        if (eflag>0) {
          numtyp e=r6inv*(lj3[ii].x*r6inv-lj3[ii].y);
          energy+=factor_lj*(e-lj3[ii].z); 
        }
        if (vflag>0) {
          virial[0] += delx*delx*force;
          virial[1] += dely*dely*force;
          virial[2] += delz*delz*force;
          virial[3] += delx*dely*force;
          virial[4] += delx*delz*force;
          virial[5] += dely*delz*force;
        }
      }

    } // for nbor
  } // if ii
  
  // Reduce answers
  if (t_per_atom>1) {
    __local acctyp red_acc[6][BLOCK_PAIR];
    
    red_acc[0][tid]=f.x;
    red_acc[1][tid]=f.y;
    red_acc[2][tid]=f.z;
    red_acc[3][tid]=energy;

    for (unsigned int s=t_per_atom/2; s>0; s>>=1) {
      if (offset < s) {
        for (int r=0; r<4; r++)
          red_acc[r][tid] += red_acc[r][tid+s];
      }
    }
    
    f.x=red_acc[0][tid];
    f.y=red_acc[1][tid];
    f.z=red_acc[2][tid];
    energy=red_acc[3][tid];

    if (vflag>0) {
      for (int r=0; r<6; r++)
        red_acc[r][tid]=virial[r];

      for (unsigned int s=t_per_atom/2; s>0; s>>=1) {
        if (offset < s) {
          for (int r=0; r<6; r++)
            red_acc[r][tid] += red_acc[r][tid+s];
        }
      }
    
      for (int r=0; r<6; r++)
        virial[r]=red_acc[r][tid];
    }
  }

  // Store answers
  if (ii<inum && offset==0) {
    __global acctyp *ap1=engv+ii;
    if (eflag>0) {
      *ap1+=energy;
      ap1+=inum;
    }
    if (vflag>0) {
      for (int i=0; i<6; i++) {
        *ap1+=virial[i];
        ap1+=inum;
      }
    }
    acctyp4 old=ans[ii];
    old.x+=f.x;
    old.y+=f.y;
    old.z+=f.z;
    ans[ii]=old;
  } // if ii
}

__kernel void kernel_lj_fast(__global numtyp4 *x_, __global numtyp4 *lj1_in, 
                             __global numtyp4* lj3_in, __global numtyp *gum, 
                             const int stride, __global int *dev_ij,
                             __global acctyp4 *ans, __global acctyp *engv,
                             __global int *err_flag, const int eflag,
                             const int vflag, const int start, const int inum,
                             const int nall, const int t_per_atom) {
  int tid=THREAD_ID_X;
  int ii=mul24((int)BLOCK_ID_X,(int)(BLOCK_SIZE_X)/t_per_atom);
  ii+=tid/t_per_atom+start;
  int offset=tid%t_per_atom;

  __local numtyp sp_lj[4];                              
  __local numtyp4 lj1[MAX_SHARED_TYPES*MAX_SHARED_TYPES];
  __local numtyp4 lj3[MAX_SHARED_TYPES*MAX_SHARED_TYPES];
  if (tid<4)
    sp_lj[tid]=gum[tid];    
  if (tid<MAX_SHARED_TYPES*MAX_SHARED_TYPES) {
    lj1[tid]=lj1_in[tid];
    if (eflag>0)
      lj3[tid]=lj3_in[tid];
  }
  
  acctyp energy=(acctyp)0;
  acctyp4 f;
  f.x=(acctyp)0;
  f.y=(acctyp)0;
  f.z=(acctyp)0;
  acctyp virial[6];
  for (int i=0; i<6; i++)
    virial[i]=(acctyp)0;
  
  __syncthreads();
  
  if (ii<inum) {
    __global int *nbor=dev_ij+ii;
    int i=*nbor;
    nbor+=stride;
    int numj=*nbor;
    nbor+=stride;
    __global int *list_end=nbor+mul24(stride,numj);
    nbor+=mul24(offset,stride);
    int n_stride=mul24(t_per_atom,stride);

    numtyp4 ix=x_[i];
    int iw=ix.w;
    int itype=mul24((int)MAX_SHARED_TYPES,iw);

    numtyp factor_lj;
    for ( ; nbor<list_end; nbor+=n_stride) {
  
      int j=*nbor;
      factor_lj = sp_lj[sbmask(j)];
      j &= NEIGHMASK;

      numtyp4 jx=x_[j];
      int mtype=itype+jx.w;

      // Compute r12
      numtyp delx = ix.x-jx.x;
      numtyp dely = ix.y-jx.y;
      numtyp delz = ix.z-jx.z;
      numtyp r2inv = delx*delx+dely*dely+delz*delz;
        
      if (r2inv<lj1[mtype].z && lj1[mtype].w==SPHERE_SPHERE) {
        r2inv=(numtyp)1.0/r2inv;
        numtyp r6inv = r2inv*r2inv*r2inv;
        numtyp force = factor_lj*r2inv*r6inv*(lj1[mtype].x*r6inv-lj1[mtype].y);
      
        f.x+=delx*force;
        f.y+=dely*force;
        f.z+=delz*force;

        if (eflag>0) {
          numtyp e=r6inv*(lj3[mtype].x*r6inv-lj3[mtype].y);
          energy+=factor_lj*(e-lj3[mtype].z); 
        }
        if (vflag>0) {
          virial[0] += delx*delx*force;
          virial[1] += dely*dely*force;
          virial[2] += delz*delz*force;
          virial[3] += delx*dely*force;
          virial[4] += delx*delz*force;
          virial[5] += dely*delz*force;
        }
      }

    } // for nbor
  } // if ii
  
  // Reduce answers
  if (t_per_atom>1) {
    __local acctyp red_acc[6][BLOCK_PAIR];
    
    red_acc[0][tid]=f.x;
    red_acc[1][tid]=f.y;
    red_acc[2][tid]=f.z;
    red_acc[3][tid]=energy;

    for (unsigned int s=t_per_atom/2; s>0; s>>=1) {
      if (offset < s) {
        for (int r=0; r<4; r++)
          red_acc[r][tid] += red_acc[r][tid+s];
      }
    }
    
    f.x=red_acc[0][tid];
    f.y=red_acc[1][tid];
    f.z=red_acc[2][tid];
    energy=red_acc[3][tid];

    if (vflag>0) {
      for (int r=0; r<6; r++)
        red_acc[r][tid]=virial[r];

      for (unsigned int s=t_per_atom/2; s>0; s>>=1) {
        if (offset < s) {
          for (int r=0; r<6; r++)
            red_acc[r][tid] += red_acc[r][tid+s];
        }
      }
    
      for (int r=0; r<6; r++)
        virial[r]=red_acc[r][tid];
    }
  }

  // Store answers
  if (ii<inum && offset==0) {
    __global acctyp *ap1=engv+ii;
    if (eflag>0) {
      *ap1+=energy;
      ap1+=inum;
    }
    if (vflag>0) {
      for (int i=0; i<6; i++) {
        *ap1+=virial[i];
        ap1+=inum;
      }
    }
    acctyp4 old=ans[ii];
    old.x+=f.x;
    old.y+=f.y;
    old.z+=f.z;
    ans[ii]=old;
  } // if ii
}

#endif

