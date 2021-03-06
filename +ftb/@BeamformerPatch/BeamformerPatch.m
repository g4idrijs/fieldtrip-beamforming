classdef BeamformerPatch < ftb.Beamformer
    %BeamformerPatch Summary of this class goes here
    %   Detailed explanation goes here
    
    properties
        % original ftb.Beamformer properties
        lf;  % leadfield Object with filters
        patches; % patch file
    end
    
    methods (Static, Access = protected)
        [source, patches] = beamformer_lcmv_patch(...
            data, leadfield, atlasfile, patches, varargin);
    end
    
    methods (Access = protected)
        obj = process_beamformer_patch(obj);
    end
    
    methods
        function obj = BeamformerPatch(params,name)
            %   params (struct or string)
            %       struct or file name
            %   name (string)
            %       object name
            
            % use Beamformer constructor
            obj@ftb.Beamformer(params,name);
            obj.prefix = 'BPatch';
            
            % double check config
            if ~isequal(obj.config.ft_sourceanalysis.method,'lcmv')
                error(['ftb:' mfilename],...
                    'only compatible with lcmv');
            end
            
            if ~isfield(obj.config,'atlas_file')
                error(['ftb:' mfilename],...
                    'missing params.atlas_file');
            end
            
            % create leadfield object
            obj.lf = ftb.Leadfield(obj.config,'patchfilt');
            
            obj.patches = '';
        end
        
        function obj = init(obj,out_folder)
            
            % call Beamformer init on main object
            init@ftb.Beamformer(obj,out_folder);
            
            % create folder for analysis step, name accounts for dependencies
            out_folder2 = fullfile(out_folder, obj.get_name());
            if ~exist(out_folder2,'dir')
                mkdir(out_folder2)
            end        
            
            % init Leadfield object
            obj.lf.init(out_folder2);
            
            % set up file names
            obj.patches = fullfile(out_folder2, 'patches.mat');
            
            obj.init_called = true;
        end
        
        function obj = process(obj)
            if ~obj.init_called
                error(['ftb:' mfilename],...
                    'not initialized');
            end
            
            % get analysis step objects
            eegObj = obj.get_dep('ftb.EEG');
            lfObj = obj.get_dep('ftb.Leadfield');
            elecObj = obj.get_dep('ftb.Electrodes');
            hmObj = obj.get_dep('ftb.Headmodel');
            
            if obj.check_file(obj.patches)
                % load data
                leadfield = ftb.util.loadvar(lfObj.leadfield);
                patches = ftb.patches.get_aal_coarse(obj.config.atlas_file);
                % FIXME this shouldn't be so specific
                
                % get the patch basis
                if ~isfield(obj.config,'ftb_patches_basis')
                    obj.config.ftb_patches_basis = {};
                end
                patches = ftb.patches.basis(patches, leadfield,...
                    obj.config.ftb_patches_basis{:});
                
                % save patches
                save(obj.patches, 'patches');
            else
                fprintf('%s: skipping ftb.patches.basis, already exists\n',...
                    strrep(class(obj),'ftb.',''));
            end
            
            % precompute filters
            if obj.check_file(obj.lf.leadfield)
                % load data
                data = ftb.util.loadvar(eegObj.timelock);
                leadfield = ftb.util.loadvar(lfObj.leadfield);
                patches = ftb.util.loadvar(obj.patches);
                
                % computer filters
                source = ftb.BeamformerPatch.beamformer_lcmv_patch(...
                    data, leadfield, patches);
                
                % save filters
                leadfield.filter = source.filters;
                leadfield.filter_label = source.patch_labels;
                save(obj.lf.leadfield, 'leadfield');
            else
                fprintf('%s: skipping beamformer_lcmv_patch, already exists\n',...
                    strrep(class(obj),'ftb.',''));
            end
            
            % source analysis
            % -----
            % process source analysis
            obj.process_deps(eegObj,obj.lf,elecObj,hmObj);
        end
        
        function plot_beampattern(obj,seed,varargin)
            %PLOT_BEAMPATTERN plots beampattern on anatomical image
            %   PLOT_BEAMPATTERN(obj, seed, ...)
            %   plots beampattern power on anatomical images. The
            %   beampattern is computed wrt a seed location and is
            %   represented by the Frobenius norm
            %
            %   Inputs
            %   ------
            %   seed (string or scalar)
            %       seed location for beampattern, you can specify an
            %       patch label or an index
            %
            %   Parameters
            %   ----------
            %   method (default = 'slice')
            %       plotting method: slice or ortho
            %   
            %   options (struct)
            %       options for ft_sourceplot, see ft_sourceplot
            
            % TODO refactor in plot_beampattern_deps and move to Beamformer
            % class
            
            p = inputParser;
            p.StructExpand = false;
            addRequired(p,'seed');
            parse(p,seed);
            
            % load leadfield
            leadfield = ftb.util.loadvar(obj.lf.leadfield);
            
            % find filter corresponding to the seed
            if ischar(p.Results.seed)
                % find a leadfield corresponding to the label
                match = lumberjack.strfindlisti(leadfield.filter_label', p.Results.seed);
                if ~any(match)
                    error('could not find %s', p.Results.seed);
                end
                filt_seed = leadfield.filter{find(match==1,1)};
            elseif isscalar(p.Results.seed)
                % use index
                filt_seed = leadfield.filter{p.Results.seed};
            else
                error(['ftb:' mfilename],...
                    'unknown seed type');
            end
            
            % create source struct
            source = [];
            source.dim = leadfield.dim;
            source.pos = leadfield.pos;
            source.inside = leadfield.inside;
            source.method = 'average';
            source.avg.pow = zeros(size(leadfield.inside));
            
            for i=1:length(leadfield.inside)
                if leadfield.inside(i)
                    source.avg.pow(i) = norm(filt_seed*leadfield.leadfield{i},'fro');
                end
            end
            
            % get MRI object
            mriObj = obj.get_dep('ftb.MRI');
            % load mri data
            mri = ftb.util.loadvar(mriObj.mri_mat);
            
            obj.plot_anatomical_deps(mri,source,varargin{:});
        end
        
        function plot_patch_resolution(obj,seed,varargin)
            %PLOT_PATCH_RESOLUTION plots patch resolution on anatomical image
            %   PLOT_PATCH_RESOLUTION(obj, seed, ...) plots patch
            %   resolution on anatomical images. The resolution is computed
            %   wrt a seed location and is represented by eq (14) of
            %   Limpiti2006
            %
            %   Inputs
            %   ------
            %   seed (string or scalar)
            %       seed patch, you can specify an patch label or an index
            %
            %   Parameters
            %   ----------
            %   method (default = 'slice')
            %       plotting method: slice or ortho
            %   
            %   options (struct)
            %       options for ft_sourceplot, see ft_sourceplot
            
            p = inputParser;
            p.StructExpand = false;
            addRequired(p,'seed');
            parse(p,seed);
            
            % load patches
            patches = ftb.util.loadvar(obj.patches);
            
            % find filter corresponding to the seed
            if ischar(p.Results.seed)
                % find a patch corresponding to the label
                match = lumberjack.strfindlisti({patches.name}, p.Results.seed);
                if ~any(match)
                    error('could not find %s', p.Results.seed);
                end
                U_seed = patches(match).U;
            elseif isscalar(p.Results.seed)
                % use index
                U_seed = patches(p.Results.see).U;
            else
                error(['ftb:' mfilename],...
                    'unknown seed type');
            end
            
            % load leadfield
            leadfield = ftb.util.loadvar(obj.lf.leadfield);
            
            % create source struct
            source = [];
            source.dim = leadfield.dim;
            source.pos = leadfield.pos;
            source.inside = leadfield.inside;
            source.method = 'average';
            source.avg.pow = zeros(size(leadfield.inside));
            
            for i=1:length(patches)
                H = patches(i).H;
                delta = trace(H'*(U_seed*U_seed')*H)/trace(H'*H);
                source.avg.pow(patches(i).inside) = delta;
            end
            
            % get MRI object
            mriObj = obj.get_dep('ftb.MRI');
            % load mri data
            mri = ftb.util.loadvar(mriObj.mri_mat);
            
            obj.plot_anatomical_deps(mri,source,varargin{:});
        end
        
    end
    
end

