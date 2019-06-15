from ...potential.potential.cpotential cimport CPotentialWrapper

cdef class BaseStreamDF:

    cdef double _lead
    cdef double _trail
    cdef public object random_state

    cdef void get_rj_vj_R(self, CPotentialWrapper potential,
                          double *prog_x, double *prog_v,
                          double prog_m, double t,
                          double *rj, double *vj, double[:, ::1] R)

    cdef void transform_from_sat(self, double[:, ::1] R,
                                 double *x, double *v,
                                 double *prog_x, double *prog_v,
                                 double *out_x, double *out_v)

    cpdef _sample(self, CPotentialWrapper potential,
                  double[:, ::1] prog_x, double[:, ::1] prog_v,
                  double[::1] prog_t, double[::1] prog_m, int[::1] nparticles)

    cpdef sample(self, hamiltonian, prog_orbit, prog_mass,
                 release_every=?, n_particles=?)
