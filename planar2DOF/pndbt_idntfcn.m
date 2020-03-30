clc; clear all; close all;

% get robot description
plnr = parse_urdf('planar_manip.urdf');

% load and process data
pendubot = pendubotDataProcessing('position_A_1.2_v_0.6.mat');

% % run data processing script
% run('pndbt_data_processing.m')

% load mapping from standard parameters to base parameters
load('pndbtBaseQR.mat')
fullRegressor2BaseRegressor = pndbtBaseQR.permutationMatrix(:, ...
                                    1:pndbtBaseQR.numberOfBaseParameters);

% compose observation matrix and torque vector
noObservations = length(pendubot.time);
W = []; Wb = []; Tau = [];
for i = 1:1:noObservations
%     qi = [pendubot.shldr_position(i), pendubot.elbw_position(i)]';
%     qdi = [pendubot.shldr_velocity_filtered(i), pendubot.elbw_velocity_filtered(i)]';
%     q2di = [pendubot.shldr_acceleration_filtered(i), pendubot.elbow_acceleration_filtered(i)]';
    
    qi = [pendubot.shldr_position(i), pendubot.elbw_position(i)]';
    qdi = [pendubot.shldr_velocity_estimated(i), pendubot.elbw_velocity_estimated(i)]';
    q2di = [pendubot.shldr_acceleration_filtered2(i), pendubot.elbow_acceleration_filtered2(i)]';
    
    Yi = regressorWithMotorDynamicsPndbt(qi, qdi, q2di);

    Ybi = Yi*fullRegressor2BaseRegressor;
    Yfrctni = frictionRegressor(qdi);
    Wb = vertcat(Wb, [Ybi, Yfrctni]);
    W = vertcat(W, [Yi, Yfrctni]);
    
    taui = [pendubot.torque_filtered(i), 0]';
%     taui = [pendubot.current(i)*0.123, 0]';
    Tau = vertcat(Tau, taui);
end


%% Usual Least Squares Approach
pi_hat = (Wb'*Wb)\(Wb'*Tau)


%% Set-up SDP optimization procedure
physicalConsistency = 1;

pi_frctn = sdpvar(6,1);
pi_b = sdpvar(pndbtBaseQR.numberOfBaseParameters, 1); % variables for base paramters
pi_d = sdpvar(15, 1); % variables for dependent paramters

% Bijective mapping from [pi_b; pi_d] to standard parameters pi
pii = pndbtBaseQR.permutationMatrix*[eye(pndbtBaseQR.numberOfBaseParameters), ...
                                    -pndbtBaseQR.beta; ...
                                    zeros(15, pndbtBaseQR.numberOfBaseParameters), ... 
                                    eye(15)]*[pi_b; pi_d];
% Density realizability of the first momentum (in ellipsoid)
% Ellipsoid is described by the equation
% (x - xc)^2/xr^2 + (y - yc)^2/yr^2 + (z - zc)^2/zr^2 = 1 or 
% (v - vc)'Qs^-1(v - vc), Qs = diag([xc^2 yc^2 zc^2])
% where xs = [xc yc zc]' is vector defining center of ellipsoid, 
% abc = [xr yr zr]' is semiaxis length
xs = [0.125 0 0]'; % center of the ellipsoid
abc = [0.125 0.015 0.005]'; % semiaxis length
Qs = diag(abc.^2); % matrix of reciprocals of the squares of the semi-axes

% Density realizability of the second momentum (in an ellipsoid)
% 
Sigma_c_1 = 0.5*trace(plnr.I(:,:,1))*eye(3) - plnr.I(:,:,1); % density weighted covariance
Epsilon_pi_1 = inv(Sigma_c_1/plnr.m(1)); % covariance ellipsoid
Q(:,:,1) = blkdiag(-Epsilon_pi_1, 1);

Sigma_c_2 = 0.5*trace(plnr.I(:,:,2))*eye(3) - plnr.I(:,:,2); % density weighted covariance
Epsilon_pi_2 = inv(Sigma_c_2/plnr.m(2)); % covariance ellipsoid
Q(:,:,2) = blkdiag(-Epsilon_pi_2, 1);

% pi_CAD = [plnr.pi(:,1); 0; plnr.pi(:,2)]; % parameters from the CAD
% w_pi = 1e-6; % regulization term

cnstr = [pii(10) < 1.2, pii(21) < 0.5]; % constraints on the mass
if physicalConsistency
    k = 1;
    for i = 1:11:21
        link_inertia_i = [pii(i),   pii(i+1), pii(i+2); ...
                          pii(i+1), pii(i+3), pii(i+4); ...
                          pii(i+2), pii(i+4), pii(i+5)];          
        frst_mmnt_i = pii(i+6:i+8);
        
        % Positive definiteness of the generalized mass matrix
        Ji = [0.5*trace(link_inertia_i)*eye(3) - link_inertia_i, ...
                frst_mmnt_i; frst_mmnt_i', pii(i+9)];

        % First moment realizability on the ellipsoid
        Ci = [pii(i+9), frst_mmnt_i' - pii(i+9)*xs';
              frst_mmnt_i - pii(i+9)*xs, pii(i+9)*Qs];
        
        % Second moment realizability on the ellipsoid
        Pi = trace(Ji*Q(:,:,k));
            
        cnstr = [cnstr, Ji > 0, Ci >= 0, Pi >= 0];
        
        k = k + 1;
    end
else
    for i = 1:11:21
        link_inertia_i = [pii(i), pii(i+1), pii(i+2); ...
                          pii(i+1), pii(i+3), pii(i+4); ...
                          pii(i+2), pii(i+4), pii(i+5)];

        frst_mmnt_i = vec2skewSymMat(pii(i+6:i+8));

        Di = [link_inertia_i, frst_mmnt_i'; frst_mmnt_i, pii(i+9)*eye(3)];
        cnstr = [cnstr, Di>0];
    end
end
% cnstr = [cnstr, pii(11) > 0, pii(10)> 0, pii(21) > 0];
cnstr = [cnstr, pii(11) > 0]; % first motor inertia constraint

% Feasibility constraints on the friction prameters 
% Columb and viscous friction coefficients are positive
for i = 1:2
   cnstr = [cnstr, pi_frctn(3*i-2) > 0, pi_frctn(3*i-1) > 0];  
end

% Defining pbjective function
obj = norm(Tau - Wb*[pi_b; pi_frctn], 2)^2;% + w_pi*norm(pii - pi_CAD);

% Solving sdp problem
sol2 = optimize(cnstr, obj, sdpsettings('solver','sdpt3'));

pi_b = value(pi_b) % variables for base paramters
pi_frctn = value(pi_frctn)

pi_stnd = pndbtBaseQR.permutationMatrix*[eye(pndbtBaseQR.numberOfBaseParameters), ...
                                        -pndbtBaseQR.beta; ...
                                        zeros(15,pndbtBaseQR.numberOfBaseParameters), ... 
                                        eye(15)]*[value(pi_b); value(pi_d)];

