# cython: boundscheck=False
# cython: nonecheck=False
# cython: cdivision=True
# cython: wraparound=False
# cython: profile=False
# cython: language_level=3

# Third-party
from astropy.utils.misc import isiterable
import cython
import astropy.units as u
import numpy as np
cimport numpy as np

# This package
from .. import combine
from ..nbody import DirectNBody
from ...potential import Hamiltonian, PotentialBase

from ...potential.potential.cpotential cimport CPotentialWrapper, CPotential
from ...potential.hamiltonian.chamiltonian import Hamiltonian

from ._coord cimport cross, norm, apply_3matrix

cdef extern from "potential/src/cpotential.h":
    double c_d2_dr2(CPotential *p, double t, double *q, double *epsilon) nogil


# TODO: if an orbit with non-static frame passed in, convert to static frame before generating
cdef class BaseStreamDF:

    @cython.embedsignature(True)
    def __init__(self, lead=True, trail=True, random_state=None):
        """TODO: documentation"""
        self._lead = int(lead)
        self._trail = int(trail)

        if random_state is None:
            random_state = np.random.RandomState()
        self.random_state = random_state

        if not self.lead and not self.trail:
            raise ValueError("You must generate either leading or trailing "
                             "tails (or both!)")

    cdef void get_rj_vj_R(self, CPotentialWrapper potential,
                          double *prog_x, double *prog_v,
                          double prog_m, double t,
                          double *rj, double *vj, double[:, ::1] R): # outputs
        # NOTE: assuming ndim=3 throughout here
        cdef:
            int i
            double dist = norm(prog_x, 3)
            double L[3]
            double Lmag, Om, d2r

        # angular momentum vector, L, and |L|
        cross(prog_x, prog_v, &L[0])
        Lnorm = norm(&L[0], 3)

        # NOTE: R goes from non-rotating frame to rotating frame!!!
        for i in range(3):
            R[0, i] = prog_x[i] / dist
            R[2, i] = L[i] / Lnorm

        # Now compute jacobi radius and relative velocity at jacobi radius
        # Note: we re-use the L array as the "epsilon" array needed by d2_dr2
        Om = Lnorm / dist**2
        d2r = c_d2_dr2(&(potential.cpotential), t, prog_x,
                       &L[0])
        rj[0] = (self._G * prog_m / (Om*Om - d2r)) ** (1/3.)
        vj[0] = Om * rj[0]

        # re-use the epsilon array to compute cross-product
        cross(&R[0, 0], &R[2, 0], &R[1, 0])
        for i in range(3):
            R[1, i] = -R[1, i]

    cdef void transform_from_sat(self, double[:, ::1] R,
                                 double *x, double *v,
                                 double *prog_x, double *prog_v,
                                 double *out_x, double *out_v):
        # from satellite coordinates to global coordinates note: the 1 is
        # because above in get_rj_vj_R(), we compute the transpose of the
        # rotation matrix we actually need
        apply_3matrix(R, x, out_x, 1)
        apply_3matrix(R, v, out_v, 1)

        for n in range(3):
            out_x[n] += prog_x[n]
            out_v[n] += prog_v[n]


    cpdef _sample(self, CPotentialWrapper potential,
                  double[:, ::1] prog_x, double[:, ::1] prog_v,
                  double[::1] prog_t, double[::1] prog_m, int[::1] nparticles):
        pass

    # ------------------------------------------------------------------------
    # Python-only:

    @property
    def lead(self):
        return self._lead

    @property
    def trail(self):
        return self._trail

    cpdef sample(self, hamiltonian, prog_orbit, prog_mass,
                 release_every=1, n_particles=1):
        """sample(hamiltonian, prog_orbit, prog_mass, release_every=1, n_particles=1)

        Generate stream particle initial conditions and initial times.

        This method is primarily meant to be used within the
        ``MockStreamGenerator``.

        Parameters
        ----------
        hamiltonian :
            TODO
        prog_orbit : `~gala.dynamics.Orbit`
            The orbit of the progenitor system.
        prog_mass : `~astropy.units.Quantity` [mass]
            The mass of the progenitor system, either a scalar quantity, or as
            an array with the same shape as the number of timesteps in the orbit
            to account for mass evolution.
        release_every : int (optional)
            Controls how often to release stream particles from each tail.
            Default: 1, meaning release particles at each timestep.
        n_particles : int, array_like (optional)
            If an integer, this controls the number of particles to release in
            each tail at each release timestep. Alternatively, you can pass in
            an array with the same shape as the number of timesteps to release
            bursts of particles at certain times (e.g., pericenter).

        Returns
        -------
        xyz : `~astropy.units.Quantity` [length]
            The initial positions for stream star particles.
        v_xyz : `~astropy.units.Quantity` [speed]
            The initial velocities for stream star particles.
        t1 : `~astropy.units.Quantity` [time]
            The initial times (i.e. times to start integrating from) for stream
            star particles.
        """
        cdef:
            CPotentialWrapper cpotential

        H = Hamiltonian(hamiltonian)
        cpotential = <CPotentialWrapper>(H.potential)

        # TODO: here, transform to static frame!

        # Coerce the input orbit into C-contiguous numpy arrays in the units of
        # the hamiltonian
        _units = H.units
        prog_x = np.ascontiguousarray(prog_orbit.xyz.decompose(_units).value.T)
        prog_v = np.ascontiguousarray(prog_orbit.v_xyz.decompose(_units).value.T)
        prog_t = prog_orbit.t.decompose(_units).value
        prog_m = prog_mass.decompose(_units).value

        if not isiterable(prog_m):
            prog_m = np.ones_like(prog_t) * prog_m

        if isiterable(n_particles):
            n_particles = np.array(n_particles).astype('i4')
            if not len(n_particles) == len(prog_t):
                raise ValueError('If passing in an array n_particles, its '
                                 'shape must match the number of timesteps in '
                                 'the progenitor orbit.')

        else:
            N = int(n_particles)
            n_particles = np.zeros_like(prog_t, dtype='i4')
            n_particles[::release_every] = N

        x, v, t1 = self._sample(cpotential,
                                prog_x, prog_v, prog_t, prog_m, n_particles)

        return (np.array(x) * _units['length'],
                np.array(v) * _units['length']/_units['time'],
                np.array(t1) * _units['time'])


cdef class StreaklineStreamDF(BaseStreamDF):

    cpdef _sample(self, CPotentialWrapper potential,
                  double[:, ::1] prog_x, double[:, ::1] prog_v,
                  double[::1] prog_t, double[::1] prog_m, int[::1] nparticles):
        cdef:
            int i, j, k, n
            int ntimes = len(prog_t)
            int total_nparticles = (self._lead + self._trail) * np.sum(nparticles)

            double[:, ::1] particle_x = np.zeros((total_nparticles, 3))
            double[:, ::1] particle_v = np.zeros((total_nparticles, 3))
            double[::1] particle_t1 = np.zeros((total_nparticles, ))

            double[::1] tmp_x = np.zeros(3)
            double[::1] tmp_v = np.zeros(3)

            double rj # jacobi radius
            double vj # relative velocity at jacobi radius
            double[:, ::1] R = np.zeros((3, 3)) # rotation to satellite coordinates

        j = 0
        for i in range(ntimes):
            self.get_rj_vj_R(potential,
                             &prog_x[i, 0], &prog_v[i, 0], prog_m[i], prog_t[i],
                             &rj, &vj, R) # outputs

            # Trailing tail
            if self._trail == 1:
                for k in range(nparticles[i]):
                    tmp_x[0] = rj
                    tmp_v[1] = vj
                    particle_t1[j+k] = prog_t[i]

                    self.transform_from_sat(R,
                                            &tmp_x[0], &tmp_v[0],
                                            &prog_x[i, 0], &prog_v[i, 0],
                                            &particle_x[j+k, 0],
                                            &particle_v[j+k, 0])

                j += nparticles[i]

            # Leading tail
            if self._lead == 1:
                for k in range(nparticles[i]):
                    tmp_x[0] = -rj
                    tmp_v[1] = -vj
                    particle_t1[j+k] = prog_t[i]

                    self.transform_from_sat(R,
                                            &tmp_x[0], &tmp_v[0],
                                            &prog_x[i, 0], &prog_v[i, 0],
                                            &particle_x[j+k, 0],
                                            &particle_v[j+k, 0])

                j += nparticles[i]

        return particle_x, particle_v, particle_t1


cdef class FardalStreamDF(BaseStreamDF):

    cpdef _sample(self, CPotentialWrapper potential,
                  double[:, ::1] prog_x, double[:, ::1] prog_v,
                  double[::1] prog_t, double[::1] prog_m, int[::1] nparticles):
        cdef:
            int i, j, k, n
            int ntimes = len(prog_t)
            int total_nparticles = (self._lead + self._trail) * np.sum(nparticles)

            double[:, ::1] particle_x = np.zeros((total_nparticles, 3))
            double[:, ::1] particle_v = np.zeros((total_nparticles, 3))
            double[::1] particle_t1 = np.zeros((total_nparticles, ))

            double[::1] tmp_x = np.zeros(3)
            double[::1] tmp_v = np.zeros(3)

            double rj # jacobi radius
            double vj # relative velocity at jacobi radius
            double[:, ::1] R = np.zeros((3, 3)) # rotation to satellite coordinates

            # for Fardal method:
            double kx
            double[::1] k_mean = np.zeros(6)
            double[::1] k_disp = np.zeros(6)

        k_mean[0] = 2. # R
        k_disp[0] = 0.5

        k_mean[2] = 0. # z
        k_disp[2] = 0.5

        k_mean[4] = 0.3 # vt
        k_disp[4] = 0.5

        k_mean[5] = 0. # vz
        k_disp[5] = 0.5

        j = 0
        for i in range(ntimes):
            self.get_rj_vj_R(potential,
                             &prog_x[i, 0], &prog_v[i, 0], prog_m[i], prog_t[i],
                             &rj, &vj, R) # outputs

            # Trailing tail
            if self._trail == 1:
                for k in range(nparticles[i]):
                    kx = self.random_state.normal(k_mean[0], k_disp[0])
                    tmp_x[0] = kx * rj
                    tmp_x[2] = self.random_state.normal(k_mean[2], k_disp[2]) * rj
                    tmp_v[1] = kx * self.random_state.normal(k_mean[4], k_disp[4]) * vj
                    tmp_v[2] = self.random_state.normal(k_mean[5], k_disp[5]) * vj
                    particle_t1[j+k] = prog_t[i]

                    self.transform_from_sat(R,
                                            &tmp_x[0], &tmp_v[0],
                                            &prog_x[i, 0], &prog_v[i, 0],
                                            &particle_x[j+k, 0],
                                            &particle_v[j+k, 0])

                j += nparticles[i]

            # Leading tail
            if self._lead == 1:
                for k in range(nparticles[i]):
                    kx = self.random_state.normal(k_mean[0], k_disp[0])
                    tmp_x[0] = kx * -rj
                    tmp_x[2] = self.random_state.normal(k_mean[2], k_disp[2]) * -rj
                    tmp_v[1] = kx * self.random_state.normal(k_mean[4], k_disp[4]) * -vj
                    tmp_v[2] = self.random_state.normal(k_mean[5], k_disp[5]) * -vj
                    particle_t1[j+k] = prog_t[i]

                    self.transform_from_sat(R,
                                            &tmp_x[0], &tmp_v[0],
                                            &prog_x[i, 0], &prog_v[i, 0],
                                            &particle_x[j+k, 0],
                                            &particle_v[j+k, 0])

                j += nparticles[i]

        return particle_x, particle_v, particle_t1


cdef class LagrangeCloudStreamDF(BaseStreamDF):

    cdef public object v_disp
    cdef double _v_disp

    @u.quantity_input(v_disp=u.km/u.s)
    def __init__(self, hamiltonian, v_disp, lead=True, trail=True):
        super().__init__(hamiltonian, lead=lead, trail=trail)

        self.v_disp = v_disp
        self._v_disp = self.v_disp.decompose(hamiltonian.units).value

    cpdef _sample(self, CPotentialWrapper potential,
                  double[:, ::1] prog_x, double[:, ::1] prog_v,
                  double[::1] prog_t, double[::1] prog_m, int[::1] nparticles):
        cdef:
            int i, j, k, n
            int ntimes = len(prog_t)
            int total_nparticles = (self._lead + self._trail) * np.sum(nparticles)

            double[:, ::1] particle_x = np.zeros((total_nparticles, 3))
            double[:, ::1] particle_v = np.zeros((total_nparticles, 3))
            double[::1] particle_t1 = np.zeros((total_nparticles, ))

            double[::1] tmp_x = np.zeros(3)
            double[::1] tmp_v = np.zeros(3)

            double rj # jacobi radius
            double vj # relative velocity at jacobi radius
            double[:, ::1] R = np.zeros((3, 3)) # rotation to satellite coordinates

        j = 0
        for i in range(ntimes):
            self.get_rj_vj_R(potential,
                             &prog_x[i, 0], &prog_v[i, 0], prog_m[i], prog_t[i],
                             &rj, &vj, R) # outputs

            # Trailing tail
            if self._trail == 1:
                for k in range(nparticles[i]):
                    tmp_x[0] = rj
                    tmp_v[0] = self.random_state.normal(0, self._v_disp)
                    tmp_v[1] = self.random_state.normal(0, self._v_disp)
                    tmp_v[2] = self.random_state.normal(0, self._v_disp)
                    particle_t1[j + k] = prog_t[i]

                    self.transform_from_sat(R,
                                            &tmp_x[0], &tmp_v[0],
                                            &prog_x[i, 0], &prog_v[i, 0],
                                            &particle_x[j+k, 0],
                                            &particle_v[j+k, 0])

                j += nparticles[i]

            # Leading tail
            if self._lead == 1:
                for k in range(nparticles[i]):
                    tmp_x[0] = -rj
                    tmp_v[0] = self.random_state.normal(0, self._v_disp)
                    tmp_v[1] = self.random_state.normal(0, self._v_disp)
                    tmp_v[2] = self.random_state.normal(0, self._v_disp)
                    particle_t1[j + k] = prog_t[i]

                    self.transform_from_sat(R,
                                            &tmp_x[0], &tmp_v[0],
                                            &prog_x[i, 0], &prog_v[i, 0],
                                            &particle_x[j+k, 0],
                                            &particle_v[j+k, 0])

                j += nparticles[i]

        return particle_x, particle_v, particle_t1
