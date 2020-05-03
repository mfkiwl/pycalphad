# cython: linetrace=True
import numpy as np
cimport numpy as np
from pycalphad.core.composition_set cimport CompositionSet
from pycalphad.core.phase_rec cimport PhaseRecord
from pycalphad.core.constants import MIN_SITE_FRACTION


cdef void compute_phase_matrix(double[:,::1] phase_matrix, double[:,::1] hess, CompositionSet compset,
                               int num_statevars, double[::1] phase_dof):
    "Compute the LHS of Eq. 41, Sundman 2015."
    cdef double[:, ::1] cons_jac_tmp = np.zeros((compset.phase_record.num_internal_cons,
                                                num_statevars + compset.phase_record.phase_dof))
    compset.phase_record.internal_cons_jac(cons_jac_tmp, phase_dof)
    phase_matrix[:compset.phase_record.phase_dof, :compset.phase_record.phase_dof] = hess[
                                                                                     num_statevars:,
                                                                                     num_statevars:]

    phase_matrix[compset.phase_record.phase_dof:compset.phase_record.phase_dof+compset.phase_record.num_internal_cons,
                 :compset.phase_record.phase_dof] = cons_jac_tmp[:, num_statevars:]
    phase_matrix[:compset.phase_record.phase_dof,
                 compset.phase_record.phase_dof:compset.phase_record.phase_dof+compset.phase_record.num_internal_cons] \
        = cons_jac_tmp[:, num_statevars:].T


cdef double compute_phase_system(double[:,::1] phase_matrix, double[::1] phase_rhs, CompositionSet compset,
                                 double[::1] delta_statevars, double[::1] chemical_potentials, double[::1] phase_dof):
    "Compute the system of equations in Eq. 41, Sundman 2015."
    cdef int i, cons_idx, comp_idx, sv_idx
    cdef int num_statevars = delta_statevars.shape[0]
    cdef int num_components = chemical_potentials.shape[0]
    cdef int num_internal_cons = compset.phase_record.num_internal_cons
    cdef double[::1] cons_tmp = np.zeros(num_internal_cons)
    cdef double[::1] grad_tmp = np.zeros(num_statevars + compset.phase_record.phase_dof)
    cdef double[:, ::1] mass_jac_tmp = np.zeros((num_components, num_statevars + compset.phase_record.phase_dof))
    cdef double[:, ::1] hess_tmp = np.zeros((num_statevars + compset.phase_record.phase_dof,
                                             num_statevars + compset.phase_record.phase_dof))

    compset.phase_record.internal_cons_func(cons_tmp, phase_dof)
    compset.phase_record.hess(hess_tmp, phase_dof)
    compset.phase_record.grad(grad_tmp, phase_dof)

    for comp_idx in range(num_components):
        compset.phase_record.mass_grad(mass_jac_tmp[comp_idx, :], phase_dof, comp_idx)

    compute_phase_matrix(phase_matrix, hess_tmp, compset, num_statevars, phase_dof)

    # Compute right-hand side of Eq. 41, Sundman 2015
    for i in range(compset.phase_record.phase_dof):
        phase_rhs[i] = -grad_tmp[num_statevars+i]
        for sv_idx in range(num_statevars):
            phase_rhs[i] -= hess_tmp[num_statevars + i, sv_idx] * delta_statevars[sv_idx]
        for comp_idx in range(num_components):
            phase_rhs[i] += chemical_potentials[comp_idx] * mass_jac_tmp[comp_idx, num_statevars + i]

    for cons_idx in range(num_internal_cons):
        phase_rhs[compset.phase_record.phase_dof + cons_idx] = -cons_tmp[cons_idx]
    return np.abs(cons_tmp).max()


cdef void fill_equilibrium_system_for_phase(double[:,::1] equilibrium_matrix, double[::1] equilibrium_rhs,
                                            double energy, double[::1] grad, double[:, ::1] hess,
                                            double[:, ::1] masses, double[:, ::1] mass_jac, double[:, ::1] e_matrix,
                                            double[::1] chemical_potentials,
                                            double[::1] phase_amt, int[::1] free_chemical_potential_indices,
                                            int[::1] free_statevar_indices, int[::1] free_stable_compset_indices,
                                            int[::1] fixed_chemical_potential_indices,
                                            int[::1] prescribed_element_indices, double[::1] prescribed_elemental_amounts,
                                            int idx, int stable_idx, int num_statevars) except +:
    cdef int comp_idx, component_idx, chempot_idx, compset_idx, statevar_idx, fixed_component_idx, component_row_offset, i, j
    cdef int num_components = chemical_potentials.shape[0]
    cdef int num_stable_phases = free_stable_compset_indices.shape[0]
    cdef int num_fixed_components = prescribed_elemental_amounts.shape[0]
    # Eq. 44
    cdef double[::1] c_G = np.zeros(e_matrix.shape[0])
    cdef double[:, ::1] c_statevars = np.zeros((e_matrix.shape[0], num_statevars))
    cdef double[:, ::1] c_component = np.zeros((num_components, e_matrix.shape[0]))
    for i in range(e_matrix.shape[0]):
        for j in range(e_matrix.shape[1]):
            c_G[i] -= e_matrix[i, j] * grad[num_statevars+j]
    for i in range(e_matrix.shape[0]):
        for j in range(e_matrix.shape[1]):
            for statevar_idx in range(num_statevars):
                c_statevars[i, statevar_idx] -= e_matrix[i, j] * hess[num_statevars + j, statevar_idx]
    for comp_idx in range(num_components):
        for i in range(e_matrix.shape[0]):
            for j in range(e_matrix.shape[1]):
                c_component[comp_idx, i] += mass_jac[comp_idx, num_statevars + j] * e_matrix[i, j]
    # KEY STEPS for filling equilibrium matrix
    # 1. Contribute to the row corresponding to this composition set
    # 1a. Loop through potential conditions to fill out each column
    # 2. Contribute to the rows of all fixed components
    # 2a. Loop through potential conditions to fill out each column
    # 3. Contribute to RHS of each component row
    # 4. Add energies to RHS of each stable composition set
    # 5. Subtract contribution from RHS due to any fixed chemical potentials
    # 6. Subtract fixed chemical potentials from each fixed component RHS

    # 1a. This phase row: free chemical potentials
    cdef int free_variable_column_offset = 0
    for i in range(free_chemical_potential_indices.shape[0]):
        chempot_idx = free_chemical_potential_indices[i]
        equilibrium_matrix[stable_idx, free_variable_column_offset + i] = masses[chempot_idx, 0]
    free_variable_column_offset += free_chemical_potential_indices.shape[0]
    # 1a. This phase row: free stable composition sets = zero contribution
    free_variable_column_offset += free_stable_compset_indices.shape[0]
    # 1a. This phase row: free state variables
    for i in range(free_statevar_indices.shape[0]):
        statevar_idx = free_statevar_indices[i]
        equilibrium_matrix[stable_idx, free_variable_column_offset + i] = -grad[statevar_idx]

    # 2. Contribute to the row of all fixed components
    component_row_offset = num_stable_phases
    for fixed_component_idx in range(num_fixed_components):
        component_idx = prescribed_element_indices[fixed_component_idx]
        free_variable_column_offset = 0
        # 2a. This component row: free chemical potentials
        for i in range(free_chemical_potential_indices.shape[0]):
            chempot_idx = free_chemical_potential_indices[i]
            for j in range(c_component.shape[1]):
                equilibrium_matrix[component_row_offset + fixed_component_idx, free_variable_column_offset + i] += \
                    phase_amt[idx] * mass_jac[component_idx, num_statevars+j] * c_component[chempot_idx, j]
        free_variable_column_offset += free_chemical_potential_indices.shape[0]
        # 2a. This component row: free stable composition sets
        for i in range(free_stable_compset_indices.shape[0]):
            compset_idx = free_stable_compset_indices[i]
            # Only fill this out if the current idx is equal to a free composition set
            if compset_idx == idx:
                equilibrium_matrix[
                    component_row_offset + fixed_component_idx, free_variable_column_offset + i] = \
                    masses[component_idx, 0]
        free_variable_column_offset += free_stable_compset_indices.shape[0]
        # 2a. This component row: free state variables
        for i in range(free_statevar_indices.shape[0]):
            statevar_idx = free_statevar_indices[i]
            for j in range(c_statevars.shape[0]):
                equilibrium_matrix[component_row_offset + fixed_component_idx, free_variable_column_offset + i] += \
                    phase_amt[idx] * mass_jac[component_idx, num_statevars+j] * c_statevars[j, statevar_idx]
        # 3.
        for j in range(c_G.shape[0]):
            equilibrium_rhs[component_row_offset + fixed_component_idx] += -phase_amt[idx] * \
                mass_jac[component_idx, num_statevars+j] * c_G[j]

    system_amount_index = component_row_offset + num_fixed_components
    # 2X. Also handle the N=1 row
    for component_idx in range(num_components):
        free_variable_column_offset = 0
        # 2a. This component row: free chemical potentials
        for i in range(free_chemical_potential_indices.shape[0]):
            chempot_idx = free_chemical_potential_indices[i]
            for j in range(c_component.shape[1]):
                equilibrium_matrix[system_amount_index, free_variable_column_offset + i] += \
                    phase_amt[idx] * mass_jac[component_idx, num_statevars+j] * c_component[chempot_idx, j]
        free_variable_column_offset += free_chemical_potential_indices.shape[0]
        # 2a. This component row: free stable composition sets
        for i in range(free_stable_compset_indices.shape[0]):
            compset_idx = free_stable_compset_indices[i]
            # Only fill this out if the current idx is equal to a free composition set
            if compset_idx == idx:
                equilibrium_matrix[system_amount_index, free_variable_column_offset + i] += masses[component_idx, 0]
        free_variable_column_offset += free_stable_compset_indices.shape[0]
        # 2a. This component row: free state variables
        for i in range(free_statevar_indices.shape[0]):
            statevar_idx = free_statevar_indices[i]
            for j in range(c_statevars.shape[0]):
                equilibrium_matrix[system_amount_index, free_variable_column_offset + i] += \
                    phase_amt[idx] * mass_jac[component_idx, num_statevars+j] * c_statevars[j, statevar_idx]
        # 3.
        for j in range(c_G.shape[0]):
            equilibrium_rhs[system_amount_index] += -phase_amt[idx] * mass_jac[component_idx, num_statevars+j] * c_G[j]
    # 4.
    equilibrium_rhs[idx] = energy
    # 5. Subtract fixed chemical potentials from each phase RHS
    for i in range(fixed_chemical_potential_indices.shape[0]):
        chempot_idx = fixed_chemical_potential_indices[i]
        equilibrium_rhs[idx] -= masses[chempot_idx, 0] * chemical_potentials[chempot_idx]
        # 6. Subtract fixed chemical potentials from each fixed component RHS
        for fixed_component_idx in range(num_fixed_components):
            component_idx = prescribed_element_indices[fixed_component_idx]
            for j in range(c_component.shape[1]):
                equilibrium_rhs[component_row_offset + fixed_component_idx] -= phase_amt[idx] * chemical_potentials[
                    chempot_idx] * mass_jac[component_idx, num_statevars+j] * c_component[chempot_idx, j]


cdef double fill_equilibrium_system(double[:,::1] equilibrium_matrix, double[::1] equilibrium_rhs,
                                    object compsets, double[::1] chemical_potentials,
                                    double[::1] current_elemental_amounts, double[::1] phase_amt,
                                    int[::1] free_chemical_potential_indices,
                                    int[::1] free_statevar_indices, int[::1] free_stable_compset_indices,
                                    int[::1] fixed_chemical_potential_indices,
                                    int[::1] prescribed_element_indices, double[::1] prescribed_elemental_amounts,
                                    int num_statevars, double prescribed_system_amount, object dof) except +:
    cdef int stable_idx, idx, component_row_offset, comp_idx, system_amount_index
    cdef CompositionSet compset
    cdef int num_components = chemical_potentials.shape[0]
    cdef int num_stable_phases = free_stable_compset_indices.shape[0]
    cdef int num_fixed_components = len(prescribed_elemental_amounts)
    cdef double mass_residual, current_system_amount
    cdef double[::1] x
    cdef double[::1,:] energy_tmp
    cdef double[::1] grad_tmp
    cdef double[:,::1] hess_tmp
    cdef double[:,::1] masses_tmp
    cdef double[:,::1] mass_jac_tmp
    cdef double[:,::1] phase_matrix
    cdef double[:,::1] e_matrix
    for stable_idx in range(free_stable_compset_indices.shape[0]):
        idx = free_stable_compset_indices[stable_idx]
        compset = compsets[idx]
        # TODO: Use better dof storage
        # Calculate key phase quantities starting here
        x = dof[idx]
        energy_tmp = np.zeros((1, 1))
        masses_tmp = np.zeros((num_components, 1))
        mass_jac_tmp = np.zeros((num_components, num_statevars + compset.phase_record.phase_dof))
        # Compute phase matrix (LHS of Eq. 41, Sundman 2015)
        phase_matrix = np.zeros(
            (compset.phase_record.phase_dof + compset.phase_record.num_internal_cons,
             compset.phase_record.phase_dof + compset.phase_record.num_internal_cons))
        hess_tmp = np.zeros((num_statevars + compset.phase_record.phase_dof,
                             num_statevars + compset.phase_record.phase_dof))
        grad_tmp = np.zeros(num_statevars + compset.phase_record.phase_dof)

        compset.phase_record.obj(energy_tmp[:, 0], x)
        for comp_idx in range(num_components):
            compset.phase_record.mass_grad(mass_jac_tmp[comp_idx, :], x, comp_idx)
            compset.phase_record.mass_obj(masses_tmp[comp_idx, :], x, comp_idx)
        compset.phase_record.hess(hess_tmp, x)
        compset.phase_record.grad(grad_tmp, x)

        compute_phase_matrix(phase_matrix, hess_tmp, compset, num_statevars, x)

        e_matrix = np.ascontiguousarray(np.linalg.inv(phase_matrix)[:compset.phase_record.phase_dof, :compset.phase_record.phase_dof])

        fill_equilibrium_system_for_phase(equilibrium_matrix, equilibrium_rhs, energy_tmp[0, 0], grad_tmp, hess_tmp,
                                          masses_tmp, mass_jac_tmp, e_matrix, chemical_potentials,
                                          phase_amt, free_chemical_potential_indices, free_statevar_indices,
                                          free_stable_compset_indices, fixed_chemical_potential_indices,
                                          prescribed_element_indices, prescribed_elemental_amounts,
                                          idx, stable_idx, num_statevars)

    # Add mass residual to fixed component row RHS, plus N=1 row
    mass_residual = 0.0
    component_row_offset = num_stable_phases
    system_amount_index = component_row_offset + num_fixed_components
    current_system_amount = float(np.sum(phase_amt))
    for fixed_component_idx in range(num_fixed_components):
        component_idx = prescribed_element_indices[fixed_component_idx]
        mass_residual += abs(
            current_elemental_amounts[component_idx] - prescribed_elemental_amounts[fixed_component_idx]) \
            / abs(prescribed_elemental_amounts[fixed_component_idx])
        equilibrium_rhs[component_row_offset + fixed_component_idx] -= current_elemental_amounts[component_idx] - \
                                                                       prescribed_elemental_amounts[
                                                                           fixed_component_idx]
    mass_residual += abs(current_system_amount - prescribed_system_amount)
    equilibrium_rhs[system_amount_index] -= current_system_amount - prescribed_system_amount
    return mass_residual


def extract_equilibrium_solution(chemical_potentials, phase_amt, delta_statevars,
                                 free_chemical_potential_indices, free_statevar_indices,
                                 free_stable_compset_indices, equilibrium_soln,
                                 largest_statevar_change, largest_phase_amt_change, dof):
    num_statevars = delta_statevars.shape[0]
    soln_index_offset = 0
    for i in range(free_chemical_potential_indices.shape[0]):
        chempot_idx = free_chemical_potential_indices[i]
        chempot_change = equilibrium_soln[soln_index_offset + i] - chemical_potentials[chempot_idx]
        percent_chempot_change = abs(chempot_change / chemical_potentials[chempot_idx])
        chemical_potentials[chempot_idx] = equilibrium_soln[soln_index_offset + i]
        largest_statevar_change[0] = max(largest_statevar_change[0], percent_chempot_change)
    soln_index_offset += free_chemical_potential_indices.shape[0]
    for i in range(free_stable_compset_indices.shape[0]):
        compset_idx = free_stable_compset_indices[i]
        phase_amt_change = float(phase_amt[compset_idx])
        phase_amt[compset_idx] += equilibrium_soln[soln_index_offset + i]
        phase_amt[compset_idx] = np.minimum(1.0, phase_amt[compset_idx])
        phase_amt[compset_idx] = np.maximum(0.0, phase_amt[compset_idx])
        phase_amt_change = phase_amt[compset_idx] - phase_amt_change
        largest_phase_amt_change[0] = max(largest_phase_amt_change[0], phase_amt_change)

    soln_index_offset += free_stable_compset_indices.shape[0]
    delta_statevars[:] = 0
    for i in range(free_statevar_indices.shape[0]):
        statevar_idx = free_statevar_indices[i]
        delta_statevars[statevar_idx] = equilibrium_soln[soln_index_offset + i]
    percent_statevar_changes = np.abs(delta_statevars / dof[0][:num_statevars])
    percent_statevar_changes[np.isnan(percent_statevar_changes)] = 0
    largest_statevar_change[0] = max(largest_statevar_change[0], np.max(percent_statevar_changes))
    for idx in range(len(dof)):
        dof[idx][:num_statevars] += delta_statevars


def check_convergence_and_change_phases(current_free_stable_compset_indices, driving_forces,
                                        largest_internal_dof_change, largest_phase_amt_change, largest_statevar_change):
    compsets_to_add = set(np.nonzero(driving_forces[:, 0] > -1e-5)[0])
    new_free_stable_compset_indices = np.array(sorted(set(current_free_stable_compset_indices) | compsets_to_add))
    converged = False
    if len(set(current_free_stable_compset_indices) - set(new_free_stable_compset_indices)) == 0:
        # feasible system, and no phases to add or remove
        if (largest_internal_dof_change < 1e-11) and (largest_phase_amt_change[0, 0] < 1e-10) and \
                (largest_statevar_change[0, 0] < 1e-1):
            converged = True
    return converged, new_free_stable_compset_indices


cpdef find_solution(compsets, int[::1] free_stable_compset_indices,
                  num_statevars, num_components, prescribed_system_amount,
                  initial_chemical_potentials, free_chemical_potential_indices, fixed_chemical_potential_indices,
                  prescribed_element_indices, prescribed_elemental_amounts,
                  free_statevar_indices, fixed_statevar_indices):
    phase_amt = np.array([compset.NP for compset in compsets])
    dof = [np.array(compset.dof) for compset in compsets]
    chemical_potentials = np.array(initial_chemical_potentials)
    delta_statevars = np.zeros(num_statevars)
    converged = False

    for iteration in range(100):
        current_elemental_amounts = np.zeros_like(chemical_potentials)
        all_phase_energies = np.zeros((len(compsets), 1))
        all_phase_amounts = np.zeros((len(compsets), len(chemical_potentials)))
        largest_statevar_change = np.zeros((1, 1))
        largest_internal_dof_change = 0
        largest_internal_cons_max_residual = 0
        largest_phase_amt_change = np.zeros((1, 1))
        # FIRST STEP: Update phase internal degrees of freedom
        for idx, compset in enumerate(compsets):
            # TODO: Use better dof storage
            x = dof[idx]
            masses_tmp = np.zeros((num_components, 1))
            # Compute phase matrix (LHS of Eq. 41, Sundman 2015)
            phase_matrix = np.zeros((compset.phase_record.phase_dof + compset.phase_record.num_internal_cons,
                                     compset.phase_record.phase_dof + compset.phase_record.num_internal_cons))
            rhs = np.zeros(compset.phase_record.phase_dof + compset.phase_record.num_internal_cons)
            internal_cons_max_residual = \
                compute_phase_system(phase_matrix, rhs, compset, delta_statevars, chemical_potentials, x)


            soln = np.linalg.solve(phase_matrix, rhs)
            delta_y = soln[:compset.phase_record.phase_dof]

            largest_internal_cons_max_residual = max(largest_internal_cons_max_residual, internal_cons_max_residual)
            old_y = np.array(x[num_statevars:])
            new_y = old_y + delta_y
            new_y[new_y < MIN_SITE_FRACTION] = MIN_SITE_FRACTION
            new_y[new_y > 1] = 1
            largest_internal_dof_change = max(largest_internal_dof_change, np.max(np.abs(new_y - old_y)))
            x[num_statevars:] = new_y

            for comp_idx in range(num_components):
                compset.phase_record.mass_obj(masses_tmp[comp_idx, :], x, comp_idx)
                all_phase_amounts[idx, comp_idx] = masses_tmp[comp_idx, 0]
                if phase_amt[idx] > 0:
                    current_elemental_amounts[comp_idx] += phase_amt[idx] * masses_tmp[comp_idx, 0]
            compset.phase_record.obj(all_phase_energies[idx, :], x)

        # SECOND STEP: Update potentials and phase amounts, according to conditions
        num_stable_phases = free_stable_compset_indices.shape[0]
        num_fixed_components = len(prescribed_elemental_amounts)
        num_free_variables = free_chemical_potential_indices.shape[0] + num_stable_phases + \
                             free_statevar_indices.shape[0]
        equilibrium_matrix = np.zeros((num_stable_phases + num_fixed_components + 1, num_free_variables))
        equilibrium_rhs = np.zeros(num_stable_phases + num_fixed_components + 1)
        if (num_stable_phases + num_fixed_components + 1) != num_free_variables:
            raise ValueError('Conditions do not obey Gibbs Phase Rule')

        mass_residual = fill_equilibrium_system(equilibrium_matrix, equilibrium_rhs, compsets, chemical_potentials,
                                                current_elemental_amounts, phase_amt, free_chemical_potential_indices,
                                                free_statevar_indices, free_stable_compset_indices,
                                                fixed_chemical_potential_indices,
                                                prescribed_element_indices,
                                                prescribed_elemental_amounts, num_statevars, prescribed_system_amount,
                                                dof)

        equilibrium_soln = np.linalg.lstsq(equilibrium_matrix, equilibrium_rhs, rcond=1e-21)
        equilibrium_soln = equilibrium_soln[0]

        extract_equilibrium_solution(chemical_potentials, phase_amt, delta_statevars,
                                     free_chemical_potential_indices, free_statevar_indices,
                                     free_stable_compset_indices, equilibrium_soln,
                                     largest_statevar_change[0], largest_phase_amt_change[0], dof)

        # Wait for mass balance to be satisfied before changing phases
        # Phases that "want" to be removed will keep having their phase_amt set to zero, so mass balance is unaffected
        system_is_feasible = (mass_residual < 1e-05) and (largest_internal_cons_max_residual < 1e-10)
        if system_is_feasible:
            free_stable_compset_indices = np.array(np.nonzero(phase_amt > MIN_SITE_FRACTION)[0], dtype=np.int32)
            # Check driving forces for metastable phases
            for idx in range(len(compsets)):
                all_phase_energies[idx, 0] -= np.dot(chemical_potentials, all_phase_amounts[idx, :])
            converged, new_free_stable_compset_indices = \
                check_convergence_and_change_phases(free_stable_compset_indices, all_phase_energies,
                                                    largest_internal_dof_change, largest_phase_amt_change,
                                                    largest_statevar_change)
            free_stable_compset_indices = np.array(new_free_stable_compset_indices, dtype=np.int32)
            if converged:
                converged = True
                break

    x = dof[0]
    for cs_dof in dof[1:]:
        x = np.r_[x, cs_dof[num_statevars:]]
    x = np.r_[x, phase_amt]

    return converged, x, chemical_potentials
