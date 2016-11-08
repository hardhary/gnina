#include "tree_gpu.h"

__device__
vecp segment_node::sum_force_and_torque(const vec *coords, const vec *forces) const {
	vecp tmp(vec(0,0,0), vec(0,0,0));
	VINA_RANGE(i, begin, end) {
		tmp.first  += forces[i];
		tmp.second += cross_product(coords[i] - origin, forces[i]);
	}
	return tmp;
}

__device__
vec segment_node::local_to_lab_direction(const vec& local_direction) const{
	vec tmp;
	tmp = orientation_m * local_direction;
	return tmp;
}

__device__
vec segment_node::local_to_lab(const vec& local_coords) const{
	vec tmp;
	tmp = origin + orientation_m * local_coords;
	return tmp;
}

__device__
void segment_node::set_coords(const vec *atom_coords, vec *coords) const{
	VINA_RANGE(i, begin, end)
		coords[i] = local_to_lab(atom_coords[i]);
}

__device__
void segment_node::set_orientation(const qt& q) { // does not normalize the orientation
	orientation_q = q;
	orientation_m = quaternion_to_r3(orientation_q);
}

__device__
void segment_node::set_orientation(float x, float y, float z, float w) { // does not normalize the orientation
	orientation_q = qt(x,y,z,w);
	orientation_m = quaternion_to_r3(orientation_q);
}

void tree_gpu::do_dfs(int parent, const branch& branch, std::vector<segment_node>& nodes) {
	segment_node node(branch.node, parent, &nodes[parent]);
	unsigned index = nodes.size();
	nodes.push_back(node);

	VINA_FOR_IN(i, branch.children) {
		do_dfs(index, branch.children[i], nodes);
	}
}

tree_gpu::tree_gpu(const heterotree<rigid_body> &ligand){
	//populate nodes in DFS order from ligand, where node zero is the root
	std::vector<segment_node> nodes;
	segment_node root(ligand.node);
	nodes.push_back(root);

	VINA_FOR_IN(i, ligand.children) {
		do_dfs(0,ligand.children[i], nodes);
	}

	num_nodes = nodes.size();
	//allocate device memory and copy
	//nodes
	cudaMalloc(&device_nodes, sizeof(segment_node)*nodes.size());
	cudaMemcpy(device_nodes, &nodes[0], sizeof(segment_node)*nodes.size(), cudaMemcpyHostToDevice);

	//forcetorques
	cudaMalloc(&force_torques, sizeof(vecp)*nodes.size());
	cudaMemset(force_torques, 0, sizeof(vecp)*nodes.size());

}

//given a gpu point, deallocate all the memory
void tree_gpu::deallocate(tree_gpu *t) {
	tree_gpu cpu;
	cudaMemcpy(&cpu, t, sizeof(tree_gpu), cudaMemcpyDeviceToHost);
	cudaFree(cpu.device_nodes);
	cudaFree(cpu.force_torques);
	cudaFree(t);
}

__device__
void tree_gpu::derivative(const vec *coords,const vec* forces, float *c){

	// assert(c.torsions.size() == num_nodes-1);
	//calculate each segments individual force/torque
	for(unsigned i = 0; i < num_nodes; i++) {
		force_torques[i] = device_nodes[i].sum_force_and_torque(coords, forces);
	}

	//have each child add its contribution to its parents force_torque
	for(unsigned i = num_nodes-1; i > 0; i--) {
		unsigned parent = device_nodes[i].parent;
		const vecp& ft = force_torques[i];
		force_torques[parent].first += ft.first;

		const segment_node& pnode = device_nodes[parent];
		const segment_node& cnode = device_nodes[i];

		vec r = cnode.origin - pnode.origin;
		force_torques[parent].second += cross_product(r, ft.first)+ft.second;

		//set torsions
		c[6+i-1] = ft.second * cnode.axis;
	}

	c[0] = force_torques[0].first[0];
	c[1] = force_torques[0].first[1];
	c[2] = force_torques[0].first[2];

	c[3] = force_torques[0].second[0];
	c[4] = force_torques[0].second[1];
	c[5] = force_torques[0].second[2];
}

__device__
void tree_gpu::set_conf(const vec *atom_coords, vec *coords, const conf_info
		*c, unsigned nlig_atoms){
	// assert(c.torsions.size() == num_nodes-1);
	// thread 0 has the root
	int index = threadIdx.x;
	segment_node& node = device_nodes[index];
	__shared__ unsigned long long natoms;
	//static_assert(sizeof(natoms) == 8,"Not the same size");
	__shared__ unsigned long long current_layer;
	__shared__ unsigned long long total_atoms;

	if (index == 0) {
		for(unsigned i = 0; i < 3; i++)
			node.origin[i] = c->position[i];
		node.set_orientation(c->orientation[0],c->orientation[1],c->orientation[2],c->orientation[3]);
		node.set_coords(atom_coords, coords);
		natoms = node.end - node.begin;
		current_layer = 0;
		total_atoms = (unsigned long long)(nlig_atoms);
	}

	__syncthreads();
	while (natoms < total_atoms) {
		if (index == 0) {
			current_layer++;
		}
		if (node.layer == current_layer) {
			segment_node& parent = device_nodes[node.parent];
			fl torsion = c->torsions[index-1];
			node.origin = parent.local_to_lab(node.relative_origin);
			node.axis = parent.local_to_lab_direction(node.relative_axis);
			node.set_orientation(
					quaternion_normalize_approx(
							angle_to_quaternion(node.axis, torsion) * parent.orientation_q));
			node.set_coords(atom_coords, coords);
			atomicAdd(&natoms, (unsigned long long)(node.end - node.begin));
		}
		__syncthreads();
	}
}